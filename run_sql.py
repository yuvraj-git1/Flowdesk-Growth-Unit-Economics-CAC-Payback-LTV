"""Run SQL files made of `-- name: x` blocks; save each block's final SELECT to outputs/x.csv.
Uses DuckDB when installed (the .sql files are DuckDB). Otherwise translates the few DuckDB-only
constructs used here to SQLite (sandbox testing only).  Usage: python run_sql.py sql/01_*.sql sql/02_*.sql ..."""
import re, sys, os, time, pandas as pd
DATA = os.environ.get("FD_DATA", "data")
TABLES = ["accounts", "subscriptions", "invoices", "payments", "refunds", "marketing_spend",
          "platform_reported_conversions", "leads", "sales_touches"]
os.makedirs("outputs", exist_ok=True)
try:
    import duckdb; DUCK = True; con = duckdb.connect("work.duckdb")
    for t in TABLES: con.execute(f"create or replace view {t} as select * from read_csv_auto('{DATA}/{t}.csv', header=true, sample_size=-1)")
    run = lambda q: con.execute(q).df(); ex = lambda q: con.execute(q)
except ImportError:
    import sqlite3; DUCK = False; fresh = not os.path.exists("work.sqlite"); con = sqlite3.connect("work.sqlite")
    if fresh:
        for t in TABLES: pd.read_csv(f"{DATA}/{t}.csv").to_sql(t, con, index=False)
        for ix in ["invoices(account_id)", "payments(invoice_id)", "refunds(payment_id)", "subscriptions(account_id)",
                   "accounts(email_domain)", "sales_touches(lead_id)", "leads(account_id)"]:
            con.execute(f"create index if not exists ix_{re.sub(r'[^a-z]', '_', ix)} on {ix}")
    def tr(q):
        q = re.sub(r"CAST\('([^']+)'\s+AS DATE\)", r"'\1'", q)
        q = re.sub(r"CAST\(date_trunc\('month',\s*([\w.]+)\)\s+AS DATE\)", r"date(\1,'start of month')", q)
        q = re.sub(r"date_diff\('second',\s*([\w.]+|'[^']+'),\s*([\w.]+|'[^']+')\)", r"((julianday(\2)-julianday(\1))*86400.0)", q)
        q = re.sub(r"date_diff\('day',\s*([\w.]+|'[^']+'),\s*([\w.]+|'[^']+')\)", r"CAST(julianday(date(\2))-julianday(date(\1)) AS INTEGER)", q)
        q = re.sub(r"date_add\(([\w.]+),\s*INTERVAL\s+(-?\d+)\s+(DAY|MONTH)\)", r"date(\1,'\2 \3')", q)
        q = re.sub(r"\bgreatest\(", "max(", q, flags=re.I); q = re.sub(r"\bleast\(", "min(", q, flags=re.I)
        q = re.sub(r"\bCREATE OR REPLACE TABLE (\w+)", r"DROP TABLE IF EXISTS \1; CREATE TABLE \1", q)
        return q
    def ex(q):
        con.executescript(tr(q)) if "DROP TABLE IF EXISTS" in tr(q) else con.execute(tr(q)); con.commit()
    run = lambda q: pd.read_sql_query(tr(q), con)
def main(path, show=6):
    txt = open(path).read(); blocks = re.split(r"^-- name:\s*(\w+)\s*$", txt, flags=re.M)
    for name, sql in zip(blocks[1::2], blocks[2::2]):
        body = "\n".join(l for l in sql.splitlines() if not l.strip().startswith("--"))
        stmts = [s.strip() for s in re.split(r";\s*\n", body.strip().rstrip(";") + "\n") if s.strip()]
        t0 = time.time()
        for st in stmts[:-1]: ex(st)
        last = stmts[-1]
        if re.match(r"(?i)\s*(create|drop)", last): ex(last); print(f"== {name}: ok [{time.time()-t0:.1f}s]"); continue
        d = run(last); d.to_csv(f"outputs/{name}.csv", index=False)
        print(f"\n== {name} ({len(d)} rows) [{time.time()-t0:.1f}s]"); print(d.head(show).to_string(index=False))
if __name__ == "__main__":
    pd.set_option("display.width", 250, "display.max_columns", 40)
    for p in sys.argv[1:]: main(p, int(os.environ.get("SHOW", 8)))
