-- ============================================================================
-- STAGE 1: PROFILE + CLEAN (channel labels, test accounts, duplicates, censoring)  [DuckDB]
-- Quarter labels use CASE, not integer division ('/' is decimal division in DuckDB).
-- Output table acct_clean = one row per account with canonical channel + population flags.
-- ============================================================================

-- name: s1_01_row_counts
SELECT 'accounts' t, COUNT(*) n, COUNT(DISTINCT account_id) n_key, MIN(created_at) first_ts, MAX(created_at) last_ts FROM accounts UNION ALL
SELECT 'subscriptions', COUNT(*), COUNT(DISTINCT account_id), MIN(started_at), MAX(started_at) FROM subscriptions UNION ALL
SELECT 'invoices', COUNT(*), COUNT(DISTINCT invoice_id), MIN(issued_at), MAX(issued_at) FROM invoices UNION ALL
SELECT 'payments', COUNT(*), COUNT(DISTINCT payment_id), MIN(attempted_at), MAX(attempted_at) FROM payments UNION ALL
SELECT 'refunds', COUNT(*), COUNT(DISTINCT refund_id), MIN(refunded_at), MAX(refunded_at) FROM refunds UNION ALL
SELECT 'marketing_spend', COUNT(*), COUNT(DISTINCT CAST(spend_date AS VARCHAR) || channel || campaign), MIN(spend_date), MAX(spend_date) FROM marketing_spend UNION ALL
SELECT 'platform_reported_conversions', COUNT(*), COUNT(DISTINCT CAST(report_date AS VARCHAR) || channel || campaign), MIN(report_date), MAX(report_date) FROM platform_reported_conversions UNION ALL
SELECT 'leads', COUNT(*), COUNT(DISTINCT lead_id), MIN(created_at), MAX(created_at) FROM leads UNION ALL
SELECT 'sales_touches', COUNT(*), COUNT(DISTINCT touch_id), MIN(touched_at), MAX(touched_at) FROM sales_touches;

-- name: s1_02_fk_orphans
-- Expect 0 everywhere. n_key in s1_01 = n proves PK uniqueness (spend/platform key = day x channel x campaign).
SELECT 'subscriptions->accounts' fk, COUNT(*) orphans FROM subscriptions s LEFT JOIN accounts a ON a.account_id=s.account_id WHERE a.account_id IS NULL UNION ALL
SELECT 'invoices->subscriptions', COUNT(*) FROM invoices i LEFT JOIN subscriptions s ON s.subscription_id=i.subscription_id WHERE s.subscription_id IS NULL UNION ALL
SELECT 'payments->invoices', COUNT(*) FROM payments p LEFT JOIN invoices i ON i.invoice_id=p.invoice_id WHERE i.invoice_id IS NULL UNION ALL
SELECT 'refunds->payments', COUNT(*) FROM refunds r LEFT JOIN payments p ON p.payment_id=r.payment_id WHERE p.payment_id IS NULL UNION ALL
SELECT 'accounts.lead_id->leads', COUNT(*) FROM accounts a LEFT JOIN leads l ON l.lead_id=a.lead_id WHERE a.lead_id IS NOT NULL AND l.lead_id IS NULL UNION ALL
SELECT 'leads.account_id->accounts', COUNT(*) FROM leads l LEFT JOIN accounts a ON a.account_id=l.account_id WHERE l.account_id IS NOT NULL AND a.account_id IS NULL UNION ALL
SELECT 'leads<->accounts lead_id mismatch', COUNT(*) FROM leads l JOIN accounts a ON a.account_id=l.account_id WHERE a.lead_id IS NULL OR a.lead_id<>l.lead_id UNION ALL
SELECT 'touches->leads', COUNT(*) FROM sales_touches t LEFT JOIN leads l ON l.lead_id=t.lead_id WHERE l.lead_id IS NULL;

-- name: s1_03_channel_map
-- P1 rule (p1/sql/03 acct_dim): lower/trim then exact keyword list -> 9 canonical channels. 'outbound' added for CRM leads.
CREATE OR REPLACE TABLE chan_map AS
WITH raw AS (SELECT signup_source raw_label, 'accounts' src FROM accounts UNION ALL SELECT lead_source, 'leads' FROM leads)
SELECT raw_label, src, COUNT(*) n,
  CASE WHEN lower(trim(raw_label)) IN ('organic_search','organic','organic search','seo','google organic') THEN 'organic_search'
       WHEN lower(trim(raw_label)) IN ('direct','(direct)','none','direct / none') THEN 'direct'
       WHEN lower(trim(raw_label)) IN ('referral','word of mouth','referral_friend','ref') THEN 'referral'
       WHEN lower(trim(raw_label)) IN ('paid_search','google ads','google / cpc','adwords','googleads','ppc') THEN 'paid_search'
       WHEN lower(trim(raw_label)) IN ('paid_social','fb','facebook ads','facebook','linkedin ads','social_paid') THEN 'paid_social'
       WHEN lower(trim(raw_label)) IN ('review_site','g2','g2 crowd','capterra','capterra review','getapp') THEN 'review_site'
       WHEN lower(trim(raw_label)) IN ('affiliate','partnerstack','aff') THEN 'affiliate'
       WHEN lower(trim(raw_label)) IN ('content_email','newsletter','email','blog') THEN 'content_email'
       WHEN lower(trim(raw_label)) IN ('partner','partners','integration_partner') THEN 'partner'
       WHEN lower(trim(raw_label)) = 'outbound' THEN 'outbound'
       ELSE 'UNMAPPED' END channel
FROM raw GROUP BY 1,2;
SELECT src, COUNT(*) raw_labels, SUM(CASE WHEN channel='UNMAPPED' THEN n ELSE 0 END) unmapped_rows,
       SUM(CASE WHEN lower(trim(raw_label))<>channel THEN n ELSE 0 END) noncanonical_rows, SUM(n) total_rows,
       ROUND(100.0*SUM(CASE WHEN lower(trim(raw_label))<>channel THEN n ELSE 0 END)/SUM(n),1) noncanonical_pct
FROM chan_map GROUP BY 1;

-- name: s1_04_duplicates_and_tests
-- Strong duplicate: same non-null email_domain, created 0-30 days after an earlier account. Mapped to the earliest one
-- (customer_id) so a duplicate that pays still counts once, under the original's channel (first touch).
CREATE OR REPLACE TABLE dup_map AS
SELECT b.account_id dup_id, MIN(a.account_id) orig_id
FROM accounts a JOIN accounts b ON a.email_domain=b.email_domain AND a.account_id<b.account_id
WHERE a.email_domain IS NOT NULL AND a.email_domain<>'flowdesk.com' AND date_diff('day', a.created_at, b.created_at) BETWEEN 0 AND 30
GROUP BY 1;
SELECT (SELECT COUNT(*) FROM accounts WHERE email_domain='flowdesk.com') test_accounts,
       (SELECT COUNT(*) FROM accounts a JOIN subscriptions s ON s.account_id=a.account_id WHERE a.email_domain='flowdesk.com') test_accounts_paid,
       COUNT(*) dup_accounts, SUM(CASE WHEN s.account_id IS NOT NULL THEN 1 ELSE 0 END) dup_accounts_paid,
       SUM(CASE WHEN d.orig_id IN (SELECT dup_id FROM dup_map) THEN 1 ELSE 0 END) chained_dups,
       SUM(CASE WHEN s.account_id IS NOT NULL AND so.account_id IS NOT NULL THEN 1 ELSE 0 END) both_paid
FROM dup_map d LEFT JOIN subscriptions s ON s.account_id=d.dup_id LEFT JOIN subscriptions so ON so.account_id=d.orig_id;

-- name: s1_05_acct_clean
-- Population = not test. is_dup rows are dropped from SIGNUP counts; their revenue rolls up to customer_id.
-- cohort_ok: signed up >= 90 days before data end (2025-12-31), i.e. before 2025-10-01 (right-censoring rule; quarter-aligned so spend and signups share the same window).
CREATE OR REPLACE TABLE acct_clean AS
SELECT a.account_id, COALESCE(d.orig_id, a.account_id) customer_id, CASE WHEN d.dup_id IS NOT NULL THEN 1 ELSE 0 END is_dup,
  CASE WHEN a.email_domain='flowdesk.com' THEN 1 ELSE 0 END is_test,
  a.created_at, substr(CAST(a.created_at AS VARCHAR),1,7) signup_month,
  substr(CAST(a.created_at AS VARCHAR),1,4) || '-Q' || CASE WHEN substr(CAST(a.created_at AS VARCHAR),6,2) IN ('01','02','03') THEN '1' WHEN substr(CAST(a.created_at AS VARCHAR),6,2) IN ('04','05','06') THEN '2' WHEN substr(CAST(a.created_at AS VARCHAR),6,2) IN ('07','08','09') THEN '3' ELSE '4' END cohort_q,
  CASE WHEN a.created_at < CAST('2025-10-01' AS DATE) THEN 1 ELSE 0 END cohort_ok,
  m.channel, a.acquisition_motion motion, a.company_size_band size_band, a.billing_currency, a.utm_campaign, a.lead_id, a.lifecycle_stage
FROM accounts a LEFT JOIN dup_map d ON d.dup_id=a.account_id
LEFT JOIN chan_map m ON m.src='accounts' AND m.raw_label=a.signup_source;
SELECT channel, COUNT(*) raw_accounts, SUM(is_test) test, SUM(CASE WHEN is_test=0 AND is_dup=1 THEN 1 ELSE 0 END) dups,
       SUM(CASE WHEN is_test=0 AND is_dup=0 THEN 1 ELSE 0 END) clean_signups,
       SUM(CASE WHEN is_test=0 AND is_dup=0 AND cohort_ok=1 THEN 1 ELSE 0 END) clean_signups_matured
FROM acct_clean GROUP BY 1 ORDER BY 5 DESC;

-- name: s1_06_spend_profile
-- Spend: spend_usd is NULL on ~7% of rows (all non-USD). Recompute = spend_amount x monthly reference FX from invoices (USD forced to 1.0).
CREATE OR REPLACE TABLE ref_fx AS
SELECT currency, substr(CAST(issued_at AS VARCHAR),1,7) ym, CASE WHEN currency='USD' THEN 1.0 ELSE AVG(fx_rate_to_usd) END fx
FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2;
CREATE OR REPLACE TABLE spend_clean AS
SELECT s.spend_id, s.spend_date, substr(CAST(s.spend_date AS VARCHAR),1,7) ym,
  substr(CAST(s.spend_date AS VARCHAR),1,4) || '-Q' || CASE WHEN substr(CAST(s.spend_date AS VARCHAR),6,2) IN ('01','02','03') THEN '1' WHEN substr(CAST(s.spend_date AS VARCHAR),6,2) IN ('04','05','06') THEN '2' WHEN substr(CAST(s.spend_date AS VARCHAR),6,2) IN ('07','08','09') THEN '3' ELSE '4' END q,
  s.channel, s.campaign, s.currency, s.impressions, s.clicks, s.spend_amount, s.spend_usd booked_usd, s.spend_amount * f.fx spend_usd_ref
FROM marketing_spend s LEFT JOIN ref_fx f ON f.currency=s.currency AND f.ym=substr(CAST(s.spend_date AS VARCHAR),1,7);
SELECT channel, COUNT(*) rows_, SUM(CASE WHEN booked_usd IS NULL THEN 1 ELSE 0 END) usd_null, SUM(CASE WHEN spend_usd_ref IS NULL THEN 1 ELSE 0 END) no_fx,
  ROUND(SUM(spend_amount),0) naive_sum_local, ROUND(SUM(booked_usd),0) booked_usd_sum, ROUND(SUM(spend_usd_ref),0) spend_usd_ref,
  ROUND(SUM(CASE WHEN booked_usd IS NOT NULL THEN spend_usd_ref - booked_usd ELSE 0 END),0) ref_minus_booked_where_both
FROM spend_clean GROUP BY 1 ORDER BY 7 DESC;

-- name: s1_07_lead_profile
-- CRM stage timestamps are not monotonic (sql_at before mql_at etc.), so funnel analysis uses lead_status, not timestamps.
SELECT COUNT(*) leads, SUM(CASE WHEN account_id IS NOT NULL THEN 1 ELSE 0 END) linked_accounts, SUM(CASE WHEN lead_status='won' THEN 1 ELSE 0 END) won,
  SUM(CASE WHEN sql_at < mql_at THEN 1 ELSE 0 END) sql_before_mql, SUM(CASE WHEN opportunity_at < sql_at THEN 1 ELSE 0 END) opp_before_sql,
  SUM(CASE WHEN closed_at < opportunity_at THEN 1 ELSE 0 END) close_before_opp,
  SUM(CASE WHEN lead_status='won' AND deal_arr_usd IS NULL THEN 1 ELSE 0 END) won_no_arr,
  SUM(CASE WHEN account_id IS NOT NULL AND lead_status<>'won' THEN 1 ELSE 0 END) linked_not_won
FROM leads;
