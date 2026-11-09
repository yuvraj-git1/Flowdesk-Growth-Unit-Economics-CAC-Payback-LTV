-- ============================================================================
-- STAGE 2: CAC, PAYBACK, LTV BY CHANNEL AND COHORT  [DuckDB]  (needs stage-1 tables)
-- Revenue = PAID invoices with >=1 succeeded payment, (subtotal - discount) ex-tax x monthly ref FX, booked in issue month,
-- minus succeeded refunds (ex-tax share, duplicate refunds removed, capped at the payment). Never raw total_usd.
-- Gross margin is NOT in the data: GM = 0.80 assumption here (adjustable in the Excel model).
-- ============================================================================

-- name: s2_01_invoice_revenue
CREATE OR REPLACE TABLE inv_rev AS
WITH ok AS (SELECT invoice_id, MAX(CASE WHEN status='succeeded' THEN 1 ELSE 0 END) has_success FROM payments GROUP BY 1)
SELECT i.invoice_id, i.account_id, i.issued_at, substr(CAST(i.issued_at AS VARCHAR),1,7) ym, i.period_start, i.period_end, i.currency,
  i.subtotal * f.fx gross_usd, (i.subtotal - i.discount_amount) * f.fx net_usd,
  CASE WHEN i.discount_amount >= i.subtotal AND i.subtotal > 0 THEN 1 ELSE 0 END full_discount,
  CASE WHEN i.coupon_redemption_id IS NOT NULL THEN 1 ELSE 0 END has_coupon,
  (CAST(substr(CAST(i.period_end AS VARCHAR),1,4) AS INTEGER) - CAST(substr(CAST(i.period_start AS VARCHAR),1,4) AS INTEGER))*12
   + CAST(substr(CAST(i.period_end AS VARCHAR),6,2) AS INTEGER) - CAST(substr(CAST(i.period_start AS VARCHAR),6,2) AS INTEGER) n_months,
  i.total_amount, i.tax_amount, f.fx
FROM invoices i JOIN ok ON ok.invoice_id=i.invoice_id AND ok.has_success=1
JOIN ref_fx f ON f.currency=i.currency AND f.ym=substr(CAST(i.issued_at AS VARCHAR),1,7)
WHERE i.status='paid';
SELECT (SELECT COUNT(*) FROM invoices WHERE status='paid') paid_invoices, COUNT(*) paid_with_success,
  SUM(full_discount) full_discount_invoices, SUM(has_coupon) coupon_invoices,
  SUM(CASE WHEN has_coupon=1 AND full_discount=0 THEN 1 ELSE 0 END) coupon_not_full,
  ROUND(SUM(gross_usd),0) gross_usd, ROUND(SUM(net_usd),0) net_usd, ROUND(SUM(gross_usd-net_usd),0) discount_usd,
  ROUND((SELECT SUM(total_usd) FROM invoices WHERE status='paid'),0) raw_total_usd_do_not_use
FROM inv_rev;

-- name: s2_02_refunds
-- Duplicate refund = same payment, same amount, second+ row. Ex-tax share = net / total of the invoice. Capped at payment amount.
CREATE OR REPLACE TABLE ref_rev AS
WITH r AS (SELECT r.*, ROW_NUMBER() OVER (PARTITION BY r.payment_id, r.amount ORDER BY r.refunded_at, r.refund_id) k FROM refunds r WHERE r.status='succeeded'),
 per_pay AS (SELECT r.payment_id, r.invoice_id, r.account_id, MIN(r.refunded_at) refunded_at, SUM(r.amount) amt, SUM(CASE WHEN k>1 THEN 1 ELSE 0 END) dups,
             SUM(CASE WHEN k>1 THEN r.amount ELSE 0 END) dup_amt FROM r GROUP BY 1,2,3)
SELECT p.payment_id, p.invoice_id, p.account_id, p.refunded_at, substr(CAST(p.refunded_at AS VARCHAR),1,7) ym, p.dups,
  least(p.amt - p.dup_amt, pay.amount) * f.fx * CASE WHEN i.total_amount > 0 THEN (i.subtotal - i.discount_amount)/i.total_amount ELSE 0 END refund_net_usd
FROM per_pay p JOIN payments pay ON pay.payment_id=p.payment_id JOIN invoices i ON i.invoice_id=p.invoice_id
JOIN ref_fx f ON f.currency=i.currency AND f.ym=substr(CAST(i.issued_at AS VARCHAR),1,7);
SELECT (SELECT COUNT(*) FROM refunds) refunds, (SELECT COUNT(*) FROM refunds WHERE status='succeeded') succeeded, COUNT(*) payments_refunded,
  SUM(dups) duplicate_refunds_removed, ROUND(SUM(refund_net_usd),0) refund_net_usd,
  SUM(CASE WHEN refund_net_usd=0 THEN 1 ELSE 0 END) zero_value_refunds FROM ref_rev;

-- name: s2_03_customer_base
-- One row per paying customer (subscription with >=1 paid invoice) with the signup attributes of its account. 1 subscription per account (s1_01).
CREATE OR REPLACE TABLE cust AS
WITH rev AS (SELECT account_id, SUM(net_usd) net_usd, SUM(gross_usd) gross_usd, COUNT(*) n_inv, SUM(full_discount) n_full,
               SUM(CASE WHEN net_usd > 0 THEN 1 ELSE 0 END) n_pos FROM inv_rev GROUP BY 1),
 rf AS (SELECT account_id, SUM(refund_net_usd) refund_usd FROM ref_rev GROUP BY 1),
 first_inv AS (SELECT account_id, net_usd / n_months mrr0, gross_usd / n_months list_mrr0, n_months first_n_months,
               ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY issued_at, invoice_id) rn FROM inv_rev)
SELECT c.account_id, c.channel, c.motion, c.size_band, c.cohort_q, c.signup_month, c.cohort_ok, c.created_at,
  s.plan, s.billing_interval, s.status, s.started_at, s.canceled_at, s.cancellation_source,
  CASE WHEN s.canceled_at IS NOT NULL THEN 1 ELSE 0 END churned,
  CASE WHEN s.cancellation_source='payment_failure' AND s.canceled_at >= CAST('2025-02-01' AS DATE) AND s.canceled_at < CAST('2025-08-01' AS DATE) THEN 1 ELSE 0 END outage_churn,
  c.utm_campaign,
  (CASE WHEN s.canceled_at IS NOT NULL THEN date_diff('second', s.started_at, s.canceled_at) ELSE date_diff('second', s.started_at, CAST('2026-01-01' AS DATE)) END) / 86400.0 / 30.4375 exposure_months,
  COALESCE(rev.net_usd,0) net_usd, COALESCE(rf.refund_usd,0) refund_usd, COALESCE(rev.net_usd,0) - COALESCE(rf.refund_usd,0) net_after_refunds,
  COALESCE(rev.gross_usd,0) gross_usd, COALESCE(rev.n_inv,0) n_inv, COALESCE(rev.n_full,0) n_full_discount, COALESCE(rev.n_pos,0) n_revenue_invoices,
  fi.mrr0, fi.list_mrr0, fi.first_n_months
FROM acct_clean c JOIN subscriptions s ON s.account_id=c.account_id
LEFT JOIN rev ON rev.account_id=c.account_id LEFT JOIN rf ON rf.account_id=c.account_id
LEFT JOIN first_inv fi ON fi.account_id=c.account_id AND fi.rn=1
WHERE c.is_test=0 AND c.is_dup=0
  AND EXISTS (SELECT 1 FROM inv_rev r WHERE r.account_id=c.account_id);  -- customer = >=1 paid invoice (94 subs never paid: excluded)
SELECT COUNT(*) customers, SUM(CASE WHEN n_inv=0 THEN 1 ELSE 0 END) no_paid_invoice, SUM(CASE WHEN n_inv>0 AND n_revenue_invoices=0 THEN 1 ELSE 0 END) only_zero_invoices,
  ROUND(SUM(net_after_refunds),0) net_after_refunds, SUM(churned) churned, ROUND(SUM(exposure_months),0) exposure_months FROM cust;

-- name: s2_04_cust_month_revenue
-- Cash net revenue per customer per month-since-signup k (k=0 is signup month). Refunds booked in refund month (negative).
CREATE OR REPLACE TABLE cust_k AS
WITH x AS (SELECT account_id, ym, net_usd v FROM inv_rev UNION ALL SELECT account_id, ym, -refund_net_usd FROM ref_rev)
SELECT c.account_id, c.channel, c.motion, c.cohort_q, c.signup_month,
  (CAST(substr(x.ym,1,4) AS INTEGER) - CAST(substr(c.signup_month,1,4) AS INTEGER))*12 + CAST(substr(x.ym,6,2) AS INTEGER) - CAST(substr(c.signup_month,6,2) AS INTEGER) k,
  SUM(x.v) net_usd
FROM x JOIN cust c ON c.account_id=x.account_id GROUP BY 1,2,3,4,5,6;
SELECT MIN(k) min_k, MAX(k) max_k, COUNT(*) rows_, ROUND(SUM(net_usd),0) net_usd FROM cust_k;

-- name: s2_05_channel_unit_economics
-- Matured cohorts only (signup 2023-01-01 .. 2025-09-30). CAC = ref-FX spend in the same window / new paying customers.
-- ARPA = first-invoice net MRR (discounts included). Churn = cancels / customer-months. LTV = ARPA x GM x (1-(1-c)^60)/c (60-month cap).
-- Payback (formula) = CAC / (ARPA x GM). 12m / 24m realised = actual cash per customer for cohorts with that much history.
CREATE OR REPLACE TABLE chan_ue AS
WITH sg AS (SELECT channel, COUNT(*) signups FROM acct_clean WHERE is_test=0 AND is_dup=0 AND cohort_ok=1 GROUP BY 1),
 sp AS (SELECT channel, SUM(spend_usd_ref) spend FROM spend_clean WHERE spend_date < CAST('2025-10-01' AS DATE) GROUP BY 1),
 cu AS (SELECT channel, COUNT(*) customers, AVG(mrr0) arpa, AVG(list_mrr0) list_arpa, SUM(churned) churns, SUM(churned - outage_churn) churns_ex_outage, SUM(exposure_months) expo,
          SUM(CASE WHEN n_revenue_invoices=0 THEN 1 ELSE 0 END) zero_rev_customers, SUM(net_after_refunds) net_rev
        FROM cust WHERE cohort_ok=1 GROUP BY 1),
 r12 AS (SELECT c.channel, COUNT(DISTINCT c.account_id) n12, SUM(CASE WHEN k.k BETWEEN 0 AND 11 THEN k.net_usd ELSE 0 END) rev12,
          SUM(CASE WHEN k.k BETWEEN 0 AND 23 THEN k.net_usd ELSE 0 END) rev24_all
        FROM cust c LEFT JOIN cust_k k ON k.account_id=c.account_id WHERE c.signup_month <= '2024-12' GROUP BY 1),
 r24 AS (SELECT c.channel, COUNT(DISTINCT c.account_id) n24, SUM(CASE WHEN k.k BETWEEN 0 AND 23 THEN k.net_usd ELSE 0 END) rev24
        FROM cust c LEFT JOIN cust_k k ON k.account_id=c.account_id WHERE c.signup_month <= '2023-12' GROUP BY 1)
SELECT sg.channel, CASE WHEN sp.spend IS NULL THEN 'unpaid' ELSE 'paid' END channel_type, sg.signups, cu.customers,
  1.0*cu.customers/sg.signups conv_rate, sp.spend, sp.spend/sg.signups cost_per_signup, sp.spend/cu.customers cac,
  cu.arpa, cu.list_arpa, cu.churns/cu.expo monthly_churn, cu.churns_ex_outage/cu.expo monthly_churn_ex_outage, cu.churns, cu.expo, cu.zero_rev_customers, cu.net_rev,
  r12.rev12/r12.n12 rev12_per_cust, r24.rev24/r24.n24 rev24_per_cust, r12.n12, r24.n24
FROM sg JOIN cu ON cu.channel=sg.channel LEFT JOIN sp ON sp.channel=sg.channel LEFT JOIN r12 ON r12.channel=sg.channel LEFT JOIN r24 ON r24.channel=sg.channel;
SELECT channel, channel_type, signups, customers, ROUND(100*conv_rate,2) conv_pct, ROUND(spend,0) spend, ROUND(cac,0) cac,
  ROUND(arpa,1) arpa_mrr, ROUND(100*monthly_churn,2) churn_pct_mo, ROUND(100*monthly_churn_ex_outage,2) churn_ex_outage_pct,
  ROUND(arpa*0.8*(1-power(1-monthly_churn,60))/monthly_churn,0) ltv_gm80,
  ROUND(arpa*0.8*(1-power(1-monthly_churn,60))/monthly_churn/cac,2) ltv_cac,
  ROUND(cac/(arpa*0.8),1) payback_months, ROUND(rev12_per_cust,0) rev12_per_cust, ROUND(rev24_per_cust,0) rev24_per_cust,
  ROUND(100.0*zero_rev_customers/customers,1) zero_rev_pct
FROM chan_ue ORDER BY channel_type, ltv_cac DESC;

-- name: s2_06_payback_curve
-- Observed cash payback: cumulative GM cash per paying customer by month since signup, only cohorts observable through month k.
-- Paid-channel CAC is joined so the curve shows the crossover month (first k where cum_gm_cash >= CAC).
WITH ks AS (SELECT DISTINCT k FROM cust_k WHERE k BETWEEN 0 AND 35),
 elig AS (SELECT c.channel, ks.k, c.account_id FROM cust c JOIN ks ON
          (CAST(substr(c.signup_month,1,4) AS INTEGER)*12 + CAST(substr(c.signup_month,6,2) AS INTEGER) + ks.k) <= 2025*12+12
          WHERE c.cohort_ok=1),
 cum AS (SELECT e.channel, e.k, COUNT(DISTINCT e.account_id) n, SUM(COALESCE(v.cum,0)) cum_net FROM elig e
         LEFT JOIN (SELECT a.account_id, ks.k, SUM(a.net_usd) cum FROM cust_k a JOIN ks ON a.k <= ks.k GROUP BY 1,2) v ON v.account_id=e.account_id AND v.k=e.k
         GROUP BY 1,2)
SELECT cum.channel, cum.k, cum.n customers_observable, ROUND(cum.cum_net/cum.n,2) cum_net_per_cust, ROUND(0.8*cum.cum_net/cum.n,2) cum_gm_per_cust,
  ROUND(u.cac,2) cac, CASE WHEN u.cac IS NOT NULL AND 0.8*cum.cum_net/cum.n >= u.cac THEN 1 ELSE 0 END paid_back
FROM cum LEFT JOIN chan_ue u ON u.channel=cum.channel ORDER BY 1,2;

-- name: s2_07_cohort_channel
-- CAC / conversion / ARPA / 12m cash by signup quarter x paid channel (cohort view; 12m only where the quarter has 12m of history).
WITH sg AS (SELECT channel, cohort_q, COUNT(*) signups FROM acct_clean WHERE is_test=0 AND is_dup=0 AND cohort_ok=1 GROUP BY 1,2),
 sp AS (SELECT channel, q cohort_q, SUM(spend_usd_ref) spend FROM spend_clean GROUP BY 1,2),
 cu AS (SELECT channel, cohort_q, COUNT(*) customers, AVG(mrr0) arpa, SUM(churned) churns, SUM(exposure_months) expo FROM cust WHERE cohort_ok=1 GROUP BY 1,2),
 r12 AS (SELECT c.channel, c.cohort_q, SUM(CASE WHEN k.k BETWEEN 0 AND 11 THEN k.net_usd ELSE 0 END) rev12 FROM cust c JOIN cust_k k ON k.account_id=c.account_id
         WHERE c.signup_month <= '2024-12' GROUP BY 1,2)
SELECT sg.channel, sg.cohort_q, sg.signups, COALESCE(cu.customers,0) customers, ROUND(100.0*COALESCE(cu.customers,0)/sg.signups,2) conv_pct,
  ROUND(sp.spend,0) spend, ROUND(sp.spend/NULLIF(cu.customers,0),0) cac, ROUND(cu.arpa,1) arpa_mrr,
  ROUND(r12.rev12/NULLIF(cu.customers,0),0) rev12_per_cust,
  ROUND(sp.spend/NULLIF(cu.customers,0)/(cu.arpa*0.8),1) payback_months_formula
FROM sg LEFT JOIN cu ON cu.channel=sg.channel AND cu.cohort_q=sg.cohort_q LEFT JOIN sp ON sp.channel=sg.channel AND sp.cohort_q=sg.cohort_q
LEFT JOIN r12 ON r12.channel=sg.channel AND r12.cohort_q=sg.cohort_q
ORDER BY 1,2;

-- name: s2_08_payback_observed
-- First month-since-signup at which cumulative GM cash per customer covers CAC (from s2_06 logic, GM 80%).
WITH ks AS (SELECT DISTINCT k FROM cust_k WHERE k BETWEEN 0 AND 35),
 elig AS (SELECT c.channel, ks.k, c.account_id FROM cust c JOIN ks ON
          (CAST(substr(c.signup_month,1,4) AS INTEGER)*12 + CAST(substr(c.signup_month,6,2) AS INTEGER) + ks.k) <= 2025*12+12 WHERE c.cohort_ok=1),
 cum AS (SELECT e.channel, e.k, COUNT(DISTINCT e.account_id) n, SUM(COALESCE(v.cum,0)) cum_net FROM elig e
         LEFT JOIN (SELECT a.account_id, ks.k, SUM(a.net_usd) cum FROM cust_k a JOIN ks ON a.k <= ks.k GROUP BY 1,2) v ON v.account_id=e.account_id AND v.k=e.k GROUP BY 1,2)
SELECT u.channel, ROUND(u.cac,0) cac, MIN(CASE WHEN 0.8*cum.cum_net/cum.n >= u.cac THEN cum.k END) payback_month_observed,
  ROUND(MAX(CASE WHEN cum.k=11 THEN 0.8*cum.cum_net/cum.n END),0) gm_cash_m12, ROUND(MAX(CASE WHEN cum.k=23 THEN 0.8*cum.cum_net/cum.n END),0) gm_cash_m24
FROM chan_ue u JOIN cum ON cum.channel=u.channel WHERE u.cac IS NOT NULL GROUP BY 1,2 ORDER BY 3;

-- name: s2_09_campaign_cac
-- Campaign view. utm_campaign is missing on ~25% of paid-channel signups (s1 check), so tagged customers are scaled up by the
-- channel's untagged share (assumes untagged signups split like tagged ones = SUGGESTIVE allocation).
WITH sp AS (SELECT channel, campaign, SUM(spend_usd_ref) spend, SUM(clicks) clicks FROM spend_clean WHERE spend_date < CAST('2025-10-01' AS DATE) GROUP BY 1,2),
 sg AS (SELECT channel, utm_campaign campaign, COUNT(*) signups FROM acct_clean WHERE is_test=0 AND is_dup=0 AND cohort_ok=1 GROUP BY 1,2),
 cu AS (SELECT channel, utm_campaign campaign, COUNT(*) customers, AVG(mrr0) arpa, SUM(churned)*1.0/SUM(exposure_months) churn FROM cust WHERE cohort_ok=1 GROUP BY 1,2),
 cov AS (SELECT channel, 1.0*SUM(CASE WHEN campaign IS NOT NULL THEN customers ELSE 0 END)/SUM(customers) tagged_share FROM cu GROUP BY 1)
SELECT sp.channel, sp.campaign, ROUND(sp.spend,0) spend, sp.clicks, sg.signups tagged_signups, cu.customers tagged_customers,
  ROUND(cu.customers/cov.tagged_share,0) est_customers, ROUND(sp.spend/(cu.customers/cov.tagged_share),0) est_cac,
  ROUND(100.0*cu.customers/sg.signups,2) conv_pct, ROUND(cu.arpa,1) arpa_mrr, ROUND(100*cu.churn,2) churn_pct_mo,
  ROUND(cu.arpa*0.8*(1-power(1-cu.churn,60))/cu.churn/(sp.spend/(cu.customers/cov.tagged_share)),2) ltv_cac
FROM sp JOIN cov ON cov.channel=sp.channel LEFT JOIN sg ON sg.channel=sp.channel AND sg.campaign=sp.campaign
LEFT JOIN cu ON cu.channel=sp.channel AND cu.campaign=sp.campaign ORDER BY 1, est_cac;

-- name: s2_10_marginal_cac_by_year
-- Is the next dollar as good as the average one? Spend, customers and CAC by signup year (2025 = Jan-Sep matured window).
WITH sp AS (SELECT channel, substr(q,1,4) y, SUM(spend_usd_ref) spend FROM spend_clean WHERE spend_date < CAST('2025-10-01' AS DATE) GROUP BY 1,2),
 cu AS (SELECT channel, substr(cohort_q,1,4) y, COUNT(*) customers, AVG(mrr0) arpa FROM cust WHERE cohort_ok=1 GROUP BY 1,2),
 sg AS (SELECT channel, substr(cohort_q,1,4) y, COUNT(*) signups FROM acct_clean WHERE is_test=0 AND is_dup=0 AND cohort_ok=1 GROUP BY 1,2)
SELECT sp.channel, sp.y, ROUND(sp.spend,0) spend, sg.signups, cu.customers, ROUND(100.0*cu.customers/sg.signups,2) conv_pct,
  ROUND(sp.spend/sg.signups,1) cost_per_signup, ROUND(sp.spend/cu.customers,0) cac, ROUND(cu.arpa,1) arpa_mrr
FROM sp JOIN cu ON cu.channel=sp.channel AND cu.y=sp.y JOIN sg ON sg.channel=sp.channel AND sg.y=sp.y ORDER BY 1,2;
