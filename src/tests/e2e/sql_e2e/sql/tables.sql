-- The tables every case reads: komira_test_oracle's datasets, the Parquet
-- files the pinned DuckDB wrote, read by DuckDB here and registered under the
-- same names by the Mojo runner (runner.mojo, open_session), so both engines
-- read the same bytes.
CREATE VIEW types AS FROM read_parquet('types.parquet');
CREATE VIEW nulls AS FROM read_parquet('nulls.parquet');
CREATE VIEW join_left AS FROM read_parquet('join_left.parquet');
CREATE VIEW join_right AS FROM read_parquet('join_right.parquet');
