-- The tables every case reads: komira_test_oracle's datasets and the
-- regression tables (sql/regression_tables.sql), the Parquet files the
-- pinned DuckDB wrote, read by DuckDB here and registered under the
-- same names by the Mojo runner (runner.mojo, open_session), so both engines
-- read the same bytes. The `_mem` views at the end are the tables komira
-- registers a second time from memory (register_arrow, the table an Arrow C
-- stream becomes); DuckDB reads them from the same files.
CREATE VIEW types AS FROM read_parquet('types.parquet');
CREATE VIEW nulls AS FROM read_parquet('nulls.parquet');
CREATE VIEW join_left AS FROM read_parquet('join_left.parquet');
CREATE VIEW join_right AS FROM read_parquet('join_right.parquet');
-- The regression tables (sql/regression_tables.sql).
CREATE VIEW agg_scalar AS FROM read_parquet('agg_scalar.parquet');
CREATE VIEW count_groups AS FROM read_parquet('count_groups.parquet');
CREATE VIEW lj_customer AS FROM read_parquet('lj_customer.parquet');
CREATE VIEW lj_orders AS FROM read_parquet('lj_orders.parquet');
CREATE VIEW distinct_pairs AS FROM read_parquet('distinct_pairs.parquet');
CREATE VIEW cross_a AS FROM read_parquet('cross_a.parquet');
CREATE VIEW cross_b AS FROM read_parquet('cross_b.parquet');
CREATE VIEW skey_probe AS FROM read_parquet('skey_probe.parquet');
CREATE VIEW skey_build AS FROM read_parquet('skey_build.parquet');
CREATE VIEW derived_l AS FROM read_parquet('derived_l.parquet');
CREATE VIEW derived_r AS FROM read_parquet('derived_r.parquet');
CREATE VIEW profit_lineitem AS FROM read_parquet('profit_lineitem.parquet');
CREATE VIEW profit_partsupp AS FROM read_parquet('profit_partsupp.parquet');
CREATE VIEW profit_supplier AS FROM read_parquet('profit_supplier.parquet');
CREATE VIEW pad_probe AS FROM read_parquet('pad_probe.parquet');
CREATE VIEW pad_build AS FROM read_parquet('pad_build.parquet');
CREATE VIEW fan_probe AS FROM read_parquet('fan_probe.parquet');
CREATE VIEW fan_build AS FROM read_parquet('fan_build.parquet');
CREATE VIEW full_l AS FROM read_parquet('full_l.parquet');
CREATE VIEW full_r AS FROM read_parquet('full_r.parquet');
CREATE VIEW in_outer AS FROM read_parquet('in_outer.parquet');
CREATE VIEW in_inner AS FROM read_parquet('in_inner.parquet');
CREATE VIEW in_supplier AS FROM read_parquet('in_supplier.parquet');
CREATE VIEW in_partsupp AS FROM read_parquet('in_partsupp.parquet');
CREATE VIEW in_part AS FROM read_parquet('in_part.parquet');
CREATE VIEW floats AS FROM read_parquet('floats.parquet');
-- The resident twins (runner.mojo, has_resident_twin).
CREATE VIEW lj_customer_mem AS FROM read_parquet('lj_customer.parquet');
CREATE VIEW lj_orders_mem AS FROM read_parquet('lj_orders.parquet');
