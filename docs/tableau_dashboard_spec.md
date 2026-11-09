# Tableau dashboard spec: Channel unit economics

**Audience:** CMO and CFO. **Question:** which paid channels pay back, and is the platform reporting honest?
**Data:** `tableau/` (CSV exports from `sql/05_exports.sql` and stage 2-4 outputs). Refresh by running `run_all.py`.

## Data sources and joins
| Source | Grain | Use |
|---|---|---|
| `tb01_customer_level.csv` | customer | Primary. LTV, churn, ARPA, motion splits. Filter `cohort_ok = 1` for unit economics |
| `tb02_spend_monthly.csv` | channel x campaign x month | Spend (ref-FX `spend_usd`; `booked_spend_usd` only for the DQ tile) |
| `tb03_signups_customers_monthly.csv` | channel x motion x signup month | Conversion, CAC numerator/denominator |
| `s2_06_payback_curve.csv` | channel x month-since-signup | Payback curves |
| `s3_04_monthly_reconciliation.csv` | channel x month | Platform vs DB |
| `st01_ci_channel.csv` | channel / channel x self-serve | CI whiskers |
Relationship: tb02 and tb03 on `channel` + month (`ym` = `signup_month`). Keep tb01 separate (customer grain) and use it as its own data source.

## Calculated fields (Tableau)
- `CAC` = SUM([spend_usd]) / SUM([customers])  (tb02/tb03 relationship, paid channels only)
- `Churn (monthly)` = SUM([churned]) / SUM([exposure_months])
- `ARPA` = AVG([first_mrr_net])
- `LTV` = [ARPA] * [p_GM] * (1 - (1 - [Churn])^[p_Horizon]) / [Churn]
- `LTV:CAC` = [LTV] / [CAC];  `Payback (months)` = [CAC] / ([ARPA] * [p_GM])
- `Over-claim ratio` = SUM([p_paid]) / SUM([d_paid])
- Parameters: `p_GM` (0.70-0.90, default 0.80), `p_Horizon` (24/36/60, default 60), `p_Motion` (All / self_serve / sales_assisted)

## Layout (1 page, 1400 x 900)
1. **KPI row:** 2025 paid spend | blended paid CAC | LTV:CAC | platform over-claim (1.28x). Use stat tiles, no sparklines.
2. **LTV:CAC by channel** (dot + CI whisker, sorted). Colour = channel (fixed: search blue `#2a78d6`, social orange `#eb6834`, review aqua `#1baf7a`, affiliate yellow `#eda100`). Reference lines at 1x and 3x. Toggle `p_Motion` to show the review-site collapse under self-serve.
3. **Payback curves:** line per channel, cumulative GM cash per customer vs months since signup; dashed CAC reference per channel.
4. **CAC by signup quarter:** line per channel (tb02/tb03), marking the 2025 step-up.
5. **Platform vs database:** paired bars per channel (claimed vs DB paid), with the ratio label; drill to month (s3_04) to show the gap is constant.
6. **Self-serve vs sales-assisted:** bar of LTV by motion within channel (tb01), tooltip with customers and churn.
Filters (one row, top): signup year, channel, motion. They apply to tiles 2-6.
Tooltips: n customers on every mark (review-site n = 50, so small-sample warnings matter).

## Accessibility and QA
Direct labels on all four channel series (yellow and aqua are below 3:1 contrast, so labels are required). One y-axis per chart. QA: CAC tile must equal `s2_05` (paid_search $633 all-period), and the over-claim ratio must equal `s3_01`.
