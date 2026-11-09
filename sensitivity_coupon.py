"""Coupon-discount sensitivity. In the P3 extract every coupon invoice (3,598 paid) carries discount = subtotal (100% off,
$0 collected). The P1 extract of the SAME invoice ids shows partial discounts (median 20%, max 75%). This re-prices those
invoices with the P1 discount to show how much LTV would rise per channel if the P3 field is an export defect.
Usage: python sensitivity_coupon.py <path to p1/data/invoices.csv>"""
import sys, pandas as pd
p1 = sys.argv[1] if len(sys.argv) > 1 else "../p1-repo/data/invoices.csv"
n = pd.read_csv("data/invoices.csv"); o = pd.read_csv(p1)[["invoice_id", "discount_amount"]].rename(columns={"discount_amount": "disc_p1"})
c = pd.read_csv("outputs/tb01_customer_level.csv")[["account_id", "channel", "motion"]]
m = n[n.status == "paid"].merge(o, on="invoice_id"); m["ym"] = m.issued_at.str[:7]
fx = m[m.fx_rate_to_usd.notna()].groupby(["currency", "ym"]).fx_rate_to_usd.mean().rename("fx").reset_index()
m = m.merge(fx, on=["currency", "ym"]); m.loc[m.currency == "USD", "fx"] = 1.0
m["net_p3"] = (m.subtotal - m.discount_amount) * m.fx; m["net_p1disc"] = (m.subtotal - m.disc_p1) * m.fx
m = m.merge(c, on="account_id")
out = pd.concat([m.groupby("channel")[["net_p3", "net_p1disc"]].sum().assign(dim="channel"),
                 m.groupby("motion")[["net_p3", "net_p1disc"]].sum().assign(dim="motion"),
                 m[["net_p3", "net_p1disc"]].sum().to_frame("all").T.assign(dim="total")])
out["uplift_pct"] = 100 * (out.net_p1disc / out.net_p3 - 1)
out = out.reset_index().rename(columns={"index": "segment"}).round(1); out.to_csv("outputs/st03_coupon_sensitivity.csv", index=False)
print(out.to_string(index=False))
print("coupon invoices differing:", int(((m.discount_amount != m.disc_p1)).sum()), "| P1 discount share median:", round((m.disc_p1 / m.subtotal)[m.discount_amount != m.disc_p1].median(), 3))
