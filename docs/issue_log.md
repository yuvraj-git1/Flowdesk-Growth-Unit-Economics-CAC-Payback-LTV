# Project 3 issue log (data problems found and how each was handled)

| # | Issue | Evidence (output) | Label | Handling |
|---|---|---|---|---|
| 1 | 46 raw signup labels / 47 CRM lead labels for 9 (+outbound) channels; 13.6% of accounts and 8.8% of leads non-canonical | s1_03 | Proven | P1 lower/trim keyword map; 0 unmapped |
| 2 | 40 internal test accounts (flowdesk.com) | s1_04 | Proven | Excluded (none paid) |
| 3 | 796 duplicate signups (same domain within 30 days) | s1_04 | Proven | Dropped from signup counts (none paid, so CAC unaffected) |
| 4 | `spend_usd` NULL on 901 rows (6.9%, all EUR/GBP). Booked total $724K vs ref-FX $776K (-$52K); naive local-currency sum $754K | s1_06 | Proven | Spend = spend_amount x monthly reference FX |
| 5 | Every coupon invoice is 100% discounted (3,598 paid at $0; payments and 94 refunds are $0 too). P1 extract of the same invoice ids: median 20%, max 75% | s2_01, st03 | Proven inconsistency; which extract is right is unknown | Base = as delivered; Optimistic scenario re-prices (+11.8% revenue overall) |
| 6 | Raw `total_usd` overstates paid-invoice value ($12.37M vs $10.0M net ex-tax at ref FX) | s2_01 | Proven | Never used |
| 7 | 94 subscriptions never had a paid invoice (85 canceled uncollectible); `first_paid_at` NULL on the same 94 | s2_03 | Proven | Not counted as customers |
| 8 | 5 duplicate refunds | s2_02 | Proven | Removed; refunds capped at payment, ex-tax share |
| 9 | ~25% of paid-channel signups have no `utm_campaign` | s2_09 | Proven | Campaign CAC scales tagged customers up (suggestive allocation) |
| 10 | Platform-reported conversions exceed the database: social 1.73x paid / 1.67x signups, search 1.11x / 1.31x; review and affiliate paid match exactly, signups +3-6% (close to raw counts before dedupe) | s3_01, s3_05 | Proven gap; cause (view-through window, double counting) suggestive | Database is the source of truth |
| 11 | Platform revenue is 1.6-2.7x first-12-month cash | s3_01 | Proven gap; definition unknown | Ignored for ROI |
| 12 | CRM stage timestamps out of order (713 SQL before MQL, 296 opp before SQL, 35 close before opp) | s1_07 | Proven | Funnel uses lead_status only |
| 13 | 4,520 leads still open, including 1,008 created in 2023 | s4_02 | Proven | CRM hygiene; open leads' touches charged to wins |
| 14 | Touches per new sales-assisted customer by touch year (24 to 67) is an artifact of open 2025 pipeline; by lead cohort it is 43 to 51 | s4_02 | Proven | Lead-cohort basis used |
| 15 | No gross-margin or sales-cost data | n/a | n/a | Assumptions in Excel with 3 scenarios |
| 16 | Feb-Jul 2025 dunning outage inflates churn (P1) | s2_05 churn_ex_outage | Proven (P1) | Base uses ex-outage churn |
