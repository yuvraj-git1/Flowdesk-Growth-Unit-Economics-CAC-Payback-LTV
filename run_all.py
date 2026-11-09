"""Rebuild everything from data/ (DuckDB if installed, else SQLite translation). Run from the p3/ folder:  python run_all.py
Optional: python run_all.py --p1-invoices /path/to/p1/data/invoices.csv  (for the coupon sensitivity)"""
import argparse, os, shutil, subprocess, sys, glob

ap = argparse.ArgumentParser()
ap.add_argument("--p1-invoices", default=os.environ.get("P1_INVOICES", "../p1-repo/data/invoices.csv"))
a = ap.parse_args()
py = sys.executable

def run(*args, required=True):
    print(f"\n$ python {' '.join(args)}", flush=True)
    r = subprocess.run([py, *args])
    if r.returncode and required: sys.exit(f"FAILED: {' '.join(args)}")
    return r.returncode

for f in ("work.sqlite", "work.duckdb"):
    if os.path.exists(f): os.remove(f)
run("run_sql.py", "sql/01_profile_clean.sql", "sql/02_unit_economics.sql", "sql/03_attribution_reconciliation.sql",
    "sql/04_motion_economics.sql", "sql/05_exports.sql")
run("stats_ci.py")
if os.path.exists(a.p1_invoices): run("sensitivity_coupon.py", a.p1_invoices)
else: print(f"P1 invoices not found at {a.p1_invoices}: coupon sensitivity skipped (Excel uses the last saved st03 file)")
run("charts.py")
run("build_excel.py")
os.makedirs("tableau", exist_ok=True)
for f in glob.glob("outputs/tb0*.csv") + [f"outputs/{n}.csv" for n in (
        "s2_05_channel_unit_economics", "s2_06_payback_curve", "s2_07_cohort_channel", "s3_04_monthly_reconciliation",
        "s4_04_motion_within_channel", "st01_ci_channel")]:
    shutil.copy(f, "tableau/")
print("\nDone. Outputs in outputs/, charts/, tableau/, excel/")
