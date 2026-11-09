-- ============================================================================
-- STAGE 3: PLATFORM-REPORTED vs DATABASE CONVERSIONS  [DuckDB]  (needs stage 1-2 tables)
-- DB truth: signups = clean accounts by channel (signup_source, P1 mapping); paid = new customers by subscription start date.
-- Platform rows carry no account ids, so reconciliation is aggregate (channel / campaign / month), never row-level.
-- ============================================================================

-- name: s3_01_channel_totals
WITH pl AS (SELECT channel, MAX(attribution_model) attribution_model, SUM(platform_signups) p_signups, SUM(platform_paid_conversions) p_paid, SUM(platform_revenue_usd) p_rev
            FROM platform_reported_conversions GROUP BY 1),
 db_s AS (SELECT channel, COUNT(*) d_signups FROM acct_clean WHERE is_test=0 AND is_dup=0 GROUP BY 1),
 db_p AS (SELECT channel, COUNT(*) d_paid, SUM(CASE WHEN n_revenue_invoices>0 THEN 1 ELSE 0 END) d_paid_rev, SUM(mrr0)*12 d_new_arr FROM cust GROUP BY 1),
 db_r AS (SELECT c.channel, SUM(k.net_usd) d_rev_12m FROM cust c JOIN cust_k k ON k.account_id=c.account_id AND k.k BETWEEN 0 AND 11 GROUP BY 1)
SELECT pl.channel, pl.attribution_model, pl.p_signups, db_s.d_signups, ROUND(1.0*pl.p_signups/db_s.d_signups,2) signup_ratio,
  pl.p_paid, db_p.d_paid, db_p.d_paid_rev, ROUND(1.0*pl.p_paid/db_p.d_paid,2) paid_ratio,
  ROUND(pl.p_rev,0) p_revenue, ROUND(db_p.d_new_arr,0) db_new_arr, ROUND(db_r.d_rev_12m,0) db_first12m_cash, ROUND(pl.p_rev/db_r.d_rev_12m,2) rev_ratio_vs_12m_cash,
  ROUND(pl.p_rev/NULLIF(pl.p_paid,0),0) p_rev_per_conv
FROM pl JOIN db_s ON db_s.channel=pl.channel JOIN db_p ON db_p.channel=pl.channel JOIN db_r ON db_r.channel=pl.channel ORDER BY paid_ratio DESC;

-- name: s3_02_overclaim_vs_company_total
-- Sum of what ALL platforms claim vs what the database says the 4 paid channels (and the whole company) produced.
SELECT (SELECT SUM(platform_paid_conversions) FROM platform_reported_conversions) platform_paid_claimed,
  (SELECT COUNT(*) FROM cust WHERE channel IN ('paid_search','paid_social','review_site','affiliate')) db_paid_4_channels,
  (SELECT COUNT(*) FROM cust) db_paid_all_channels,
  (SELECT SUM(platform_signups) FROM platform_reported_conversions) platform_signups_claimed,
  (SELECT COUNT(*) FROM acct_clean WHERE is_test=0 AND is_dup=0 AND channel IN ('paid_search','paid_social','review_site','affiliate')) db_signups_4_channels,
  (SELECT COUNT(*) FROM acct_clean WHERE is_test=0 AND is_dup=0) db_signups_all;

-- name: s3_03_campaign_reconciliation
-- Campaign level vs utm_campaign-tagged DB rows (+ untagged share shown so the gap is not over-read).
WITH pl AS (SELECT channel, campaign, SUM(platform_signups) p_signups, SUM(platform_paid_conversions) p_paid FROM platform_reported_conversions GROUP BY 1,2),
 ds AS (SELECT channel, utm_campaign campaign, COUNT(*) d_signups FROM acct_clean WHERE is_test=0 AND is_dup=0 GROUP BY 1,2),
 dp AS (SELECT channel, utm_campaign campaign, COUNT(*) d_paid FROM cust GROUP BY 1,2)
SELECT pl.channel, pl.campaign, pl.p_signups, ds.d_signups tagged_db_signups, ROUND(1.0*pl.p_signups/ds.d_signups,2) signup_ratio_vs_tagged,
  pl.p_paid, dp.d_paid tagged_db_paid, ROUND(1.0*pl.p_paid/dp.d_paid,2) paid_ratio_vs_tagged
FROM pl LEFT JOIN ds ON ds.channel=pl.channel AND ds.campaign=pl.campaign LEFT JOIN dp ON dp.channel=pl.channel AND dp.campaign=pl.campaign
ORDER BY 1, 8 DESC;

-- name: s3_04_monthly_reconciliation
-- Month x channel: is the gap constant (window/definition) or does it move (tracking change)? DB paid by subscription start month.
WITH pl AS (SELECT channel, substr(CAST(report_date AS VARCHAR),1,7) ym, SUM(platform_signups) p_signups, SUM(platform_paid_conversions) p_paid, SUM(platform_revenue_usd) p_rev
            FROM platform_reported_conversions GROUP BY 1,2),
 ds AS (SELECT channel, signup_month ym, COUNT(*) d_signups FROM acct_clean WHERE is_test=0 AND is_dup=0 GROUP BY 1,2),
 dp AS (SELECT channel, substr(CAST(started_at AS VARCHAR),1,7) ym, COUNT(*) d_paid FROM cust GROUP BY 1,2),
 sp AS (SELECT channel, ym, SUM(spend_usd_ref) spend FROM spend_clean GROUP BY 1,2)
SELECT pl.channel, pl.ym, ROUND(sp.spend,0) spend, pl.p_signups, COALESCE(ds.d_signups,0) d_signups, pl.p_paid, COALESCE(dp.d_paid,0) d_paid, ROUND(pl.p_rev,0) p_rev,
  ROUND(sp.spend/NULLIF(pl.p_paid,0),0) platform_cac, ROUND(sp.spend/NULLIF(dp.d_paid,0),0) db_cac
FROM pl LEFT JOIN ds ON ds.channel=pl.channel AND ds.ym=pl.ym LEFT JOIN dp ON dp.channel=pl.channel AND dp.ym=pl.ym LEFT JOIN sp ON sp.channel=pl.channel AND sp.ym=pl.ym
ORDER BY 1,2;

-- name: s3_05_yearly_ratio
WITH m AS (SELECT channel, substr(ym,1,4) y, SUM(p_signups) ps, SUM(d_signups) dsg, SUM(p_paid) pp, SUM(d_paid) dp, SUM(spend) spend FROM (
  SELECT pl.channel, pl.ym, pl.p_signups, COALESCE(ds.d_signups,0) d_signups, pl.p_paid, COALESCE(dp.d_paid,0) d_paid, sp.spend FROM
   (SELECT channel, substr(CAST(report_date AS VARCHAR),1,7) ym, SUM(platform_signups) p_signups, SUM(platform_paid_conversions) p_paid FROM platform_reported_conversions GROUP BY 1,2) pl
   LEFT JOIN (SELECT channel, signup_month ym, COUNT(*) d_signups FROM acct_clean WHERE is_test=0 AND is_dup=0 GROUP BY 1,2) ds ON ds.channel=pl.channel AND ds.ym=pl.ym
   LEFT JOIN (SELECT channel, substr(CAST(started_at AS VARCHAR),1,7) ym, COUNT(*) d_paid FROM cust GROUP BY 1,2) dp ON dp.channel=pl.channel AND dp.ym=pl.ym
   LEFT JOIN (SELECT channel, ym, SUM(spend_usd_ref) spend FROM spend_clean GROUP BY 1,2) sp ON sp.channel=pl.channel AND sp.ym=pl.ym) z GROUP BY 1,2)
SELECT channel, y, ps platform_signups, dsg db_signups, ROUND(1.0*ps/dsg,2) signup_ratio, pp platform_paid, dp db_paid, ROUND(1.0*pp/dp,2) paid_ratio,
  ROUND(spend/pp,0) platform_cac, ROUND(spend/dp,0) db_cac FROM m ORDER BY 1,2;
