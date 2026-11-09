"""Uncertainty for stage 2/4 (scipy + numpy only). Reads outputs/ written by the SQL stages.
Conversion: Wilson 95% CI. Churn: exact Poisson CI on cancels / customer-months. LTV:CAC: bootstrap (2,000 draws):
customer count ~ Binomial(signups, conv), customers resampled with replacement -> ARPA, churn, LTV (GM 80%, 60m cap), CAC=spend/k."""
import numpy as np, pandas as pd
from scipy import stats
rng = np.random.default_rng(7); GM, CAP = 0.80, 60
ue = pd.read_csv("outputs/s2_05_channel_unit_economics.csv")
c = pd.read_csv("outputs/tb01_customer_level.csv"); c = c[c.cohort_ok == 1]
seg = {f"{ch}": c[c.channel == ch] for ch in ue.channel}
# self-serve-only view of paid channels (review_site is propped up by sales-assisted deals)
sg = pd.read_csv("outputs/tb03_signups_customers_monthly.csv"); sg = sg[sg.cohort_ok == 1]
spend = ue.set_index("channel").spend
def ltv(arpa, ch): return arpa * GM * (1 - (1 - ch) ** CAP) / ch
rows = []
def run(name, cust, signups, sp):
    k, n = len(cust), signups; churns, expo = cust.churned.sum(), cust.exposure_months.sum()
    lo_c, hi_c = stats.binomtest(k, n).proportion_ci(method="wilson")
    lo_r, hi_r = stats.chi2.ppf(0.025, 2 * churns) / 2 / expo, stats.chi2.ppf(0.975, 2 * churns + 2) / 2 / expo
    arpa, ch = cust.first_mrr_net.mean(), churns / expo
    out = dict(segment=name, signups=n, customers=k, conv_pct=100 * k / n, conv_lo=100 * lo_c, conv_hi=100 * hi_c,
               churn_pct=100 * ch, churn_lo=100 * lo_r, churn_hi=100 * hi_r, arpa=arpa, ltv=ltv(arpa, ch))
    if sp == sp and sp is not None:
        m, e, ch_a = cust.first_mrr_net.values, cust.exposure_months.values, cust.churned.values; r = []
        for _ in range(2000):
            kk = rng.binomial(n, k / n); idx = rng.integers(0, k, kk)
            cb = max(ch_a[idx].sum(), 0.5) / e[idx].sum(); r.append(ltv(m[idx].mean(), cb) / (sp / kk))
        out.update(cac=sp / k, ltv_cac=ltv(arpa, ch) / (sp / k), ltv_cac_lo=np.percentile(r, 2.5), ltv_cac_hi=np.percentile(r, 97.5))
    rows.append(out)
for ch in ue.channel:
    run(ch, seg[ch], int(ue.set_index("channel").signups[ch]), spend.get(ch))
for ch in ["paid_search", "paid_social", "review_site", "affiliate"]:
    s = int(sg[(sg.channel == ch) & (sg.motion == "self_serve")].signups.sum())
    run(ch + "|self_serve_only", c[(c.channel == ch) & (c.motion == "self_serve")], s, spend[ch])  # all spend charged to self-serve
d = pd.DataFrame(rows).round(2); d.to_csv("outputs/st01_ci_channel.csv", index=False)
pd.set_option("display.width", 250); print(d.to_string(index=False))
# review_site vs other paid channels: churn rate ratio (exact conditional binomial test)
rs = c[c.channel == "review_site"]; ot = c[c.channel.isin(["paid_search", "paid_social", "affiliate"])]
x1, t1, x2, t2 = rs.churned.sum(), rs.exposure_months.sum(), ot.churned.sum(), ot.exposure_months.sum()
p = stats.binomtest(int(x1), int(x1 + x2), t1 / (t1 + t2)).pvalue
print(f"\nreview_site churn {x1}/{t1:.0f}m vs other paid {x2}/{t2:.0f}m: rate ratio {(x1/t1)/(x2/t2):.2f}, p={p:.4f}")
pd.DataFrame([dict(test="review_site vs other paid churn rate ratio", ratio=(x1/t1)/(x2/t2), p_value=p)]).to_csv("outputs/st02_review_churn_test.csv", index=False)
