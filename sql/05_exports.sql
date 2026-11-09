-- ============================================================================
-- STAGE 6: TABLEAU / EXCEL EXPORTS  [DuckDB]  (needs stage 1-4 tables). Written to outputs/; copied to tableau/ by build script.
-- ============================================================================

-- name: tb01_customer_level
SELECT account_id, channel, motion, size_band, cohort_q, signup_month, cohort_ok, plan, billing_interval, status, cancellation_source,
  churned, outage_churn, ROUND(exposure_months,2) exposure_months, ROUND(mrr0,2) first_mrr_net, ROUND(list_mrr0,2) first_mrr_list,
  ROUND(net_usd,2) net_revenue_usd, ROUND(refund_usd,2) refunds_usd, ROUND(net_after_refunds,2) net_after_refunds_usd,
  n_inv, n_full_discount, CASE WHEN n_revenue_invoices=0 THEN 1 ELSE 0 END zero_revenue_customer, utm_campaign
FROM cust ORDER BY account_id;

-- name: tb02_spend_monthly
SELECT channel, campaign, ym, ROUND(SUM(spend_usd_ref),2) spend_usd, ROUND(SUM(booked_usd),2) booked_spend_usd, SUM(impressions) impressions, SUM(clicks) clicks
FROM spend_clean GROUP BY 1,2,3 ORDER BY 1,2,3;

-- name: tb03_signups_customers_monthly
SELECT a.channel, a.motion, a.signup_month, COUNT(*) signups, SUM(CASE WHEN c.account_id IS NOT NULL THEN 1 ELSE 0 END) customers, a.cohort_ok
FROM acct_clean a LEFT JOIN cust c ON c.account_id=a.account_id WHERE a.is_test=0 AND a.is_dup=0 GROUP BY 1,2,3,6 ORDER BY 1,2,3;
