# Flowdesk Project 3: growth unit economics (CAC, payback, LTV by channel)

## Findings first
- **Next $50K:** paid search +$30K, affiliate +$15K, paid social +$10K, review site -$5K. Base case: about 58 new customers, $225K lifetime GM, **$163K net value vs $137K pro rata (+19%)**. It still wins in the conservative scenario. *(Model output; depends on assumptions.)*
- **Calls:** paid search **Scale** (LTV:CAC 5.2x, CI 4.5-6.0), affiliate **Scale** (6.6x, small base), paid social **Scale small** (5.0x, judged on DB conversions only), review site **Cut** (2.3x blended, 1.1x fully loaded, **0.3x self-serve**). *(Proven on data; LTV uses an assumed 80% GM.)*
- **Review site is not a top channel** (contradicts marketing): 1.8% signup-to-paid, 62% of its customers needed sales, churn 1.7x other paid channels (p = 0.01). *(Proven; n = 50.)*
- **Platform over-claim:** 1,482 claimed vs 1,160 real paid conversions (+28%). Social 1.73x, constant every year (view-through definition). Search 1.11x. Review and affiliate match exactly. *(Gap proven; cause suggestive.)*
- **2025 CAC rose 36-86% in every paid channel**, because signup-to-paid conversion fell about 40% everywhere, organic included. This is the P1 conversion drop, not channel decay. *(Proven.)*
- **Sales-assisted LTV is $9.3K vs $2.5K self-serve**, in every channel and size band. Sales cost per deal is estimated at $1.5K-3.7K vs a break-even of about $6.8K. *(Direction proven; cost assumed.)*
- **Data defect:** in this extract, every coupon invoice is 100% discounted. The P1 extract shows a median 20% on the same invoices. Re-pricing raises LTV 10-25% and does not change the ranking. *(Proven inconsistency.)*

One-pager: `docs/executive_summary.md`. Model: `excel/flowdesk_budget_model.xlsx`. Issues: `docs/issue_log.md`. Dashboard: `docs/tableau_dashboard_spec.md`.

## Structure
```
data/          9 synthetic CSVs (data dictionary in docs/)
sql/00_setup.sql                      DuckDB views
sql/01_profile_clean.sql              stage 1: keys, FKs, channel map, test/dup accounts, acct_clean, spend FX, CRM checks
sql/02_unit_economics.sql             stage 2: revenue, refunds, customers, CAC, LTV, payback (formula + observed), cohorts, campaigns, CAC by year
sql/03_attribution_reconciliation.sql stage 3: platform vs DB by channel, campaign, month, year
sql/04_motion_economics.sql           stage 4: self-serve vs sales-assisted, sales effort, sales CAC, mix checks, CRM funnel
sql/05_exports.sql                    stage 6: Tableau / Excel extracts
stats_ci.py           Wilson / exact-Poisson CIs, bootstrap LTV:CAC, review-site churn test (scipy)
sensitivity_coupon.py coupon-discount sensitivity vs P1 extract
charts.py, build_excel.py, run_sql.py, run_all.py
outputs/ (every query result), tableau/, charts/, excel/, docs/
```
## Reproduce
```bash
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python run_all.py          # SQL -> stats -> charts -> Excel; rewrites outputs/, charts/, tableau/, excel/
```
Optional coupon sensitivity (needs the Project 1 invoices): `python run_all.py --p1-invoices ../p1-repo/data/invoices.csv`. Without it that step is skipped and the saved `outputs/st03_coupon_sensitivity.csv` is used.
Run everything from the repo root. `work.duckdb` is built on the fly and git-ignored.

## Data
All CSVs are synthetic (generated for the fictional company Flowdesk); no real customer data. Company names and domains are fake.


## Definitions
- Population: not `flowdesk.com`, not a duplicate. Matured cohorts = signups 2023-01-01 to 2025-09-30 (at least 90 days of history; 96% of conversions happen within 90 days).
- Customer: subscription with at least one paid invoice that has a succeeded payment (4,091).
- Revenue: (subtotal - discount) ex-tax x monthly reference FX (USD = 1.0), minus succeeded refunds (ex-tax share, duplicates removed).
- CAC: ref-FX spend in the window / new customers from the same window's signups. Channel = signup_source (first touch, P1 map).
- LTV = first-invoice net MRR x GM x (1-(1-churn)^60)/churn. Payback = CAC / (ARPA x GM). Observed payback = first month the cumulative GM cash per customer is at least CAC.
