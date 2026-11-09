-- DuckDB setup for Project 3. Run from the p3/ folder in ONE session:
--   duckdb work.duckdb < sql/00_setup.sql ; then .read sql/01_profile_clean.sql ... 05  (or: python run_sql.py sql/01*.sql ...)
CREATE OR REPLACE VIEW accounts AS SELECT * FROM read_csv_auto('data/accounts.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW subscriptions AS SELECT * FROM read_csv_auto('data/subscriptions.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW invoices AS SELECT * FROM read_csv_auto('data/invoices.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW payments AS SELECT * FROM read_csv_auto('data/payments.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW refunds AS SELECT * FROM read_csv_auto('data/refunds.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW marketing_spend AS SELECT * FROM read_csv_auto('data/marketing_spend.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW platform_reported_conversions AS SELECT * FROM read_csv_auto('data/platform_reported_conversions.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW leads AS SELECT * FROM read_csv_auto('data/leads.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW sales_touches AS SELECT * FROM read_csv_auto('data/sales_touches.csv', header=true, sample_size=-1);
