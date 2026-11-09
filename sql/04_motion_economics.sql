-- ============================================================================
-- STAGE 4: SELF-SERVE vs SALES-ASSISTED ECONOMICS  [DuckDB]  (needs stage 1-2 tables)
-- Sales cost is NOT in the data. We measure sales EFFORT (touches, logged minutes) per lead and per won customer, then price it
-- with two assumptions (kept in the Excel model): (a) loaded rep cost $90K/yr x 8 reps, (b) cost per touch-hour $75 with
-- email/trial_extension = 10 min and contract_sent = 30 min when duration_minutes is NULL.
-- ============================================================================

-- name: s4_01_motion_summary
WITH sg AS (SELECT motion, COUNT(*) signups FROM acct_clean WHERE is_test=0 AND is_dup=0 AND cohort_ok=1 GROUP BY 1),
 cu AS (SELECT motion, COUNT(*) customers, AVG(mrr0) arpa, AVG(list_mrr0) list_arpa, SUM(churned) churns, SUM(churned-outage_churn) churns_xo, SUM(exposure_months) expo,
          AVG(CASE WHEN billing_interval='annual' THEN 1.0 ELSE 0 END) annual_share, AVG(CASE WHEN plan='business' THEN 1.0 ELSE 0 END) business_share,
          AVG(CASE WHEN n_revenue_invoices=0 THEN 1.0 ELSE 0 END) zero_rev_share FROM cust WHERE cohort_ok=1 GROUP BY 1),
 r12 AS (SELECT c.motion, COUNT(DISTINCT c.account_id) n12, SUM(CASE WHEN k.k BETWEEN 0 AND 11 THEN k.net_usd ELSE 0 END) rev12
         FROM cust c LEFT JOIN cust_k k ON k.account_id=c.account_id WHERE c.signup_month <= '2024-12' GROUP BY 1)
SELECT sg.motion, sg.signups, cu.customers, ROUND(100.0*cu.customers/sg.signups,2) conv_pct, ROUND(cu.arpa,1) arpa_mrr, ROUND(cu.list_arpa,1) list_arpa_mrr,
  ROUND(100.0*cu.churns/cu.expo,2) churn_pct_mo, ROUND(100.0*cu.churns_xo/cu.expo,2) churn_ex_outage_pct,
  ROUND(cu.arpa*0.8*(1-power(1-cu.churns/cu.expo,60))/(cu.churns/cu.expo),0) ltv_gm80,
  ROUND(r12.rev12/r12.n12,0) rev12_per_cust, ROUND(100*cu.annual_share,1) annual_pct, ROUND(100*cu.business_share,1) business_pct, ROUND(100*cu.zero_rev_share,1) zero_rev_pct
FROM sg JOIN cu ON cu.motion=sg.motion JOIN r12 ON r12.motion=sg.motion;

-- name: s4_02_sales_effort
-- All touches (incl. lost/open leads) are a cost of the won customers. touch_mins: logged duration, else the default per touch type.
CREATE OR REPLACE TABLE touch_cost AS
SELECT t.*, l.lead_status, CASE WHEN t.duration_minutes IS NOT NULL THEN t.duration_minutes
   WHEN t.touch_type IN ('email','trial_extension') THEN 10 WHEN t.touch_type='contract_sent' THEN 30 ELSE 30 END AS touch_mins
FROM sales_touches t JOIN leads l ON l.lead_id=t.lead_id;
-- Lead-CREATION cohort basis (touch-year basis is misleading: open 2025 pipeline inflates touches per win).
SELECT substr(CAST(l.created_at AS VARCHAR),1,4) lead_cohort, COUNT(DISTINCT l.lead_id) leads, SUM(CASE WHEN l.lead_status='won' THEN 1 ELSE 0 END) won,
  SUM(CASE WHEN l.lead_status IN ('new','mql','sql','opportunity') THEN 1 ELSE 0 END) still_open,
  ROUND(100.0*SUM(CASE WHEN l.lead_status='won' THEN 1 ELSE 0 END)/COUNT(DISTINCT l.lead_id),1) win_pct,
  SUM(t.n) touches, ROUND(SUM(t.mins)/60.0,0) AS total_hours, ROUND(1.0*SUM(t.n)/COUNT(DISTINCT l.lead_id),2) touches_per_lead,
  ROUND(1.0*SUM(t.n)/SUM(CASE WHEN l.lead_status='won' THEN 1 ELSE 0 END),1) touches_per_win, ROUND(SUM(t.mins)/60.0/SUM(CASE WHEN l.lead_status='won' THEN 1 ELSE 0 END),1) hours_per_win
FROM leads l LEFT JOIN (SELECT lead_id, COUNT(*) n, SUM(touch_mins) mins FROM touch_cost GROUP BY 1) t ON t.lead_id=l.lead_id
GROUP BY 1 ORDER BY 1;

-- name: s4_03_sales_cac
-- Two pricing assumptions for sales cost per sales-assisted customer (all years, all leads' touches included).
WITH e AS (SELECT COUNT(*) touches, SUM(touch_mins)/60.0 AS tot_hours FROM touch_cost),
 n AS (SELECT COUNT(*) sa_customers FROM cust WHERE motion='sales_assisted')
SELECT n.sa_customers, e.touches, ROUND(e.tot_hours,0) AS total_hours, ROUND(1.0*e.touches/n.sa_customers,1) touches_per_customer,
  ROUND(e.tot_hours/n.sa_customers,1) hours_per_customer,
  ROUND(e.tot_hours*75/n.sa_customers,0) sales_cac_touch_hour_75,
  ROUND(90000.0*8*3/n.sa_customers,0) sales_cac_loaded_8reps_90k
FROM e, n;

-- name: s4_04_motion_within_channel
-- Mix check (Simpson guard): does sales-assisted still win inside each channel and size band? Small cells = SUGGESTIVE.
SELECT 'channel' dim, channel seg, motion, COUNT(*) customers, ROUND(AVG(mrr0),1) arpa_mrr, ROUND(100.0*SUM(churned)/SUM(exposure_months),2) churn_pct_mo,
  ROUND(AVG(mrr0)*0.8*(1-power(1-1.0*SUM(churned)/SUM(exposure_months),60))/(1.0*SUM(churned)/SUM(exposure_months)),0) ltv_gm80
FROM cust GROUP BY 1,2,3
UNION ALL
SELECT 'size_band', COALESCE(size_band,'(null)'), motion, COUNT(*), ROUND(AVG(mrr0),1), ROUND(100.0*SUM(churned)/SUM(exposure_months),2),
  ROUND(AVG(mrr0)*0.8*(1-power(1-1.0*SUM(churned)/SUM(exposure_months),60))/(1.0*SUM(churned)/SUM(exposure_months)),0)
FROM cust GROUP BY 1,2,3 ORDER BY 1,2,3;

-- name: s4_05_lead_funnel_by_source
-- CRM funnel by normalised lead source. deal_arr_usd = list ARR (s4 check: deal_arr / first-invoice list ARR = 1.00 median).
SELECT m.channel lead_channel, COUNT(*) leads, SUM(CASE WHEN l.lead_status IN ('sql','opportunity','won','lost') THEN 1 ELSE 0 END) reached_sql_or_beyond,
  SUM(CASE WHEN l.lead_status='won' THEN 1 ELSE 0 END) won, ROUND(100.0*SUM(CASE WHEN l.lead_status='won' THEN 1 ELSE 0 END)/COUNT(*),1) win_pct_of_leads,
  ROUND(AVG(l.deal_arr_usd),0) avg_deal_arr, ROUND(1.0*SUM(COALESCE(t.touch_id,0))/NULLIF(SUM(CASE WHEN l.lead_status='won' THEN 1 ELSE 0 END),0),1) touches_per_win
FROM leads l JOIN chan_map m ON m.src='leads' AND m.raw_label=l.lead_source
LEFT JOIN (SELECT lead_id, COUNT(*) touch_id FROM sales_touches GROUP BY 1) t ON t.lead_id=l.lead_id
GROUP BY 1 ORDER BY won DESC;
