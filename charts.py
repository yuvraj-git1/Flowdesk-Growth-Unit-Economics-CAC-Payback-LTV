"""Four portfolio charts from outputs/ (matplotlib). Fixed channel colours (validated palette, direct labels for contrast relief)."""
import pandas as pd, matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
C = {"paid_search": "#2a78d6", "paid_social": "#eb6834", "review_site": "#1baf7a", "affiliate": "#eda100"}
PAID = list(C); INK, MUTED = "#0b0b0b", "#52514e"
plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False, "axes.edgecolor": "#bbbbbb",
                     "axes.grid": True, "grid.color": "#ececec", "axes.axisbelow": True, "figure.facecolor": "#fcfcfb", "axes.facecolor": "#fcfcfb"})
ci = pd.read_csv("outputs/st01_ci_channel.csv").set_index("segment")
# 1 LTV:CAC with CI, blended vs self-serve only
fig, ax = plt.subplots(figsize=(8, 4.2))
for i, ch in enumerate(PAID):
    for k, (seg, lab, mk) in enumerate(((ch, "all customers", "o"), (ch + "|self_serve_only", "self-serve only", "D"))):
        y = i + (0.18 if k == 0 else -0.18); r = ci.loc[seg]
        ax.plot([r.ltv_cac_lo, r.ltv_cac_hi], [y, y], color=C[ch], lw=2, alpha=0.55 if k else 1)
        ax.plot(r.ltv_cac, y, mk, color=C[ch], ms=8, mec="#fcfcfb", mew=2, alpha=1 if k == 0 else 0.6)
        ax.text(r.ltv_cac_hi + 0.15, y, f"{r.ltv_cac:.1f}x  {lab}", va="center", color=INK, fontsize=9)
ax.axvline(3, color=MUTED, lw=1, ls="--"); ax.text(3.05, -0.62, "3x bar", color=MUTED, fontsize=9)
ax.axvline(1, color=MUTED, lw=1, ls=":"); ax.text(1.05, -0.62, "break-even", color=MUTED, fontsize=9)
ax.set_yticks(range(4), PAID); ax.set_xlim(0, 13); ax.set_ylim(-0.75, 3.5); ax.set_xlabel("LTV : marketing CAC (GM 80%, 60-month cap), 95% bootstrap CI")
ax.set_title("Review-site self-serve customers never pay back (0.3x); other paid channels clear 3x", loc="left", fontsize=11, color=INK)
fig.tight_layout(); fig.savefig("charts/01_ltv_cac_by_channel.png", dpi=200); plt.close()
# 2 payback curves
pc = pd.read_csv("outputs/s2_06_payback_curve.csv"); fig, ax = plt.subplots(figsize=(8, 4.2))
for ch in PAID:
    d = pc[(pc.channel == ch) & (pc.k <= 24)]; ax.plot(d.k, d.cum_gm_per_cust, color=C[ch], lw=2)
    ax.axhline(d.cac.iloc[0], color=C[ch], lw=1, ls="--", alpha=0.8)
    off = {"paid_search": 90, "affiliate": -90}.get(ch, 0)
    ax.text(24.3, d.cum_gm_per_cust.iloc[-1] + off, f"{ch} (CAC ${d.cac.iloc[0]:,.0f})", va="center", color=INK, fontsize=9)
ax.text(12.5, 300, "dashed lines = marketing CAC per customer (sales cost not included)", color=MUTED, fontsize=8)
ax.set_xlim(0, 32); ax.set_xlabel("Months since signup"); ax.set_ylabel("Cumulative gross-margin cash per customer ($)")
ax.set_title("Per customer, cash covers marketing CAC in 1-4 months; review-site customers\nlook rich because 62% are sales-assisted deals (sales cost not shown)", loc="left", fontsize=11, color=INK)
fig.tight_layout(); fig.savefig("charts/02_payback_curves.png", dpi=200); plt.close()
# 3 platform vs DB
a = pd.read_csv("outputs/s3_01_channel_totals.csv").set_index("channel").loc[PAID]; fig, ax = plt.subplots(figsize=(8, 4))
x = range(4)
ax.bar([i - 0.2 for i in x], a.p_paid, 0.38, color=[C[c] for c in PAID], alpha=0.45, label="platform-claimed", edgecolor="#fcfcfb", lw=2)
ax.bar([i + 0.2 for i in x], a.d_paid, 0.38, color=[C[c] for c in PAID], label="database", edgecolor="#fcfcfb", lw=2)
for i, ch in enumerate(PAID):
    ax.text(i - 0.2, a.p_paid[ch] + 10, f"{a.p_paid[ch]:,}", ha="center", fontsize=9, color=INK)
    ax.text(i + 0.2, a.d_paid[ch] + 10, f"{a.d_paid[ch]:,}", ha="center", fontsize=9, color=INK)
    ax.text(i, -95, f"{a.paid_ratio[ch]:.2f}x claimed", ha="center", fontsize=9, color=MUTED)
ax.set_xticks(list(x), PAID); ax.set_ylim(-130, 800); ax.set_ylabel("Paid conversions 2023-2025")
ax.legend(frameon=False, loc="upper right"); ax.set_title("Paid social claims 1.73x the customers the database can find", loc="left", fontsize=11, color=INK)
fig.tight_layout(); fig.savefig("charts/03_platform_vs_db.png", dpi=200); plt.close()
# 4 CAC by year
y = pd.read_csv("outputs/s2_10_marginal_cac_by_year.csv"); fig, ax = plt.subplots(figsize=(8, 4))
for ch in PAID:
    d = y[y.channel == ch]; ax.plot(d.y.astype(str), d.cac, "o-", color=C[ch], lw=2, ms=8, mec="#fcfcfb", mew=2)
    ax.text(2.08, d.cac.iloc[-1], f"{ch} ${d.cac.iloc[-1]:,.0f}", va="center", color=INK, fontsize=9)
ax.set_xlim(-0.2, 2.9); ax.set_ylabel("Marketing CAC per new customer ($)"); ax.set_xlabel("Signup year (2025 = Jan-Sep cohorts)")
ax.set_title("2025 CAC rose 36-86% vs 2024 as conversion fell in every channel", loc="left", fontsize=11, color=INK)
fig.tight_layout(); fig.savefig("charts/04_cac_by_year.png", dpi=200); plt.close(); print("charts ok")
