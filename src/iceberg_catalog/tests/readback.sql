-- The Iceberg tables komira's write sink wrote (iceberg_write_runner/main.mojo
-- says which, and by which ids), read back by the pinned DuckDB's iceberg
-- extension. Each table is the directory `db/<table>`, scanned at its
-- `metadata/v3.metadata.json` by `iceberg_scan('db/<table>', version = '3',
-- allow_moved_paths = true)`: the paths the metadata holds
-- (s3://wh/db/<table>/metadata/..., .../data/...) are resolved against that
-- table directory instead.
--
-- For each table one row `<table>.check.tsv`: the rows the scan returns, the
-- rows of the hand-written expected table, the rows in one and not the other
-- (as multisets, NULL equal to NULL), the columns' names and types as DuckDB
-- reads them, and for each Parquet file the sink wrote (named by the number of
-- the uuid in its name) the field id of the schema root and `name=id
-- repetition` of each leaf column.
COPY (
  WITH scan AS (SELECT * FROM iceberg_scan('db/appended', version = '3', allow_moved_paths = true)),
  want AS (SELECT id::BIGINT AS id, name::VARCHAR AS name, amount::DOUBLE AS amount, flag::BOOLEAN AS flag, "day"::DATE AS "day", qty::INTEGER AS qty FROM (VALUES (1, 'n1', 1.5, false, DATE '2026-12-14', 2), (2, NULL, NULL, NULL, NULL, NULL), (3, 'n3', 3.5, false, DATE '2026-12-16', 6), (10, 'n10', 10.5, true, DATE '2026-12-23', 20), (11, 'n11', 11.5, false, DATE '2026-12-24', 22)) AS v(id, name, amount, flag, "day", qty))
  SELECT
    (SELECT count(*) FROM scan) AS scan_rows,
    (SELECT count(*) FROM want) AS want_rows,
    (SELECT count(*) FROM (SELECT * FROM scan EXCEPT ALL SELECT * FROM want)) + (SELECT count(*) FROM (SELECT * FROM want EXCEPT ALL SELECT * FROM scan)) AS differing_rows,
    (SELECT string_agg(column_name || ' ' || column_type, ', ') FROM (DESCRIBE SELECT * FROM iceberg_scan('db/appended', version = '3', allow_moved_paths = true))) AS columns,
    (SELECT coalesce(CAST(field_id AS VARCHAR), 'none') FROM parquet_schema('db/appended/data/00000000-0000-7000-8000-000000000001-0.parquet') LIMIT 1) AS root_1,
    (SELECT string_agg(name || '=' || coalesce(CAST(field_id AS VARCHAR), 'none') || ' ' || coalesce(repetition_type, 'none'), ', ') FROM (SELECT * FROM parquet_schema('db/appended/data/00000000-0000-7000-8000-000000000001-0.parquet') OFFSET 1)) AS leaves_1,
    (SELECT coalesce(CAST(field_id AS VARCHAR), 'none') FROM parquet_schema('db/appended/data/00000000-0000-7000-8000-000000000003-0.parquet') LIMIT 1) AS root_3,
    (SELECT string_agg(name || '=' || coalesce(CAST(field_id AS VARCHAR), 'none') || ' ' || coalesce(repetition_type, 'none'), ', ') FROM (SELECT * FROM parquet_schema('db/appended/data/00000000-0000-7000-8000-000000000003-0.parquet') OFFSET 1)) AS leaves_3
) TO 'appended.check.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (
  WITH scan AS (SELECT * FROM iceberg_scan('db/overwritten', version = '3', allow_moved_paths = true)),
  want AS (SELECT id::BIGINT AS id, name::VARCHAR AS name, amount::DOUBLE AS amount, flag::BOOLEAN AS flag, "day"::DATE AS "day", qty::INTEGER AS qty FROM (VALUES (100, NULL, NULL, NULL, NULL, NULL), (101, 'n101', 101.5, false, DATE '2027-03-24', 202)) AS v(id, name, amount, flag, "day", qty))
  SELECT
    (SELECT count(*) FROM scan) AS scan_rows,
    (SELECT count(*) FROM want) AS want_rows,
    (SELECT count(*) FROM (SELECT * FROM scan EXCEPT ALL SELECT * FROM want)) + (SELECT count(*) FROM (SELECT * FROM want EXCEPT ALL SELECT * FROM scan)) AS differing_rows,
    (SELECT string_agg(column_name || ' ' || column_type, ', ') FROM (DESCRIBE SELECT * FROM iceberg_scan('db/overwritten', version = '3', allow_moved_paths = true))) AS columns,
    (SELECT coalesce(CAST(field_id AS VARCHAR), 'none') FROM parquet_schema('db/overwritten/data/00000000-0000-7000-8000-000000000005-0.parquet') LIMIT 1) AS root_5,
    (SELECT string_agg(name || '=' || coalesce(CAST(field_id AS VARCHAR), 'none') || ' ' || coalesce(repetition_type, 'none'), ', ') FROM (SELECT * FROM parquet_schema('db/overwritten/data/00000000-0000-7000-8000-000000000005-0.parquet') OFFSET 1)) AS leaves_5,
    (SELECT coalesce(CAST(field_id AS VARCHAR), 'none') FROM parquet_schema('db/overwritten/data/00000000-0000-7000-8000-000000000007-0.parquet') LIMIT 1) AS root_7,
    (SELECT string_agg(name || '=' || coalesce(CAST(field_id AS VARCHAR), 'none') || ' ' || coalesce(repetition_type, 'none'), ', ') FROM (SELECT * FROM parquet_schema('db/overwritten/data/00000000-0000-7000-8000-000000000007-0.parquet') OFFSET 1)) AS leaves_7
) TO 'overwritten.check.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (
  WITH scan AS (SELECT * FROM iceberg_scan('db/emptied', version = '3', allow_moved_paths = true)),
  want AS (SELECT NULL::BIGINT AS id, NULL::VARCHAR AS name, NULL::DOUBLE AS amount, NULL::BOOLEAN AS flag, NULL::DATE AS "day", NULL::INTEGER AS qty WHERE false)
  SELECT
    (SELECT count(*) FROM scan) AS scan_rows,
    (SELECT count(*) FROM want) AS want_rows,
    (SELECT count(*) FROM (SELECT * FROM scan EXCEPT ALL SELECT * FROM want)) + (SELECT count(*) FROM (SELECT * FROM want EXCEPT ALL SELECT * FROM scan)) AS differing_rows,
    (SELECT string_agg(column_name || ' ' || column_type, ', ') FROM (DESCRIBE SELECT * FROM iceberg_scan('db/emptied', version = '3', allow_moved_paths = true))) AS columns,
    (SELECT coalesce(CAST(field_id AS VARCHAR), 'none') FROM parquet_schema('db/emptied/data/00000000-0000-7000-8000-000000000009-0.parquet') LIMIT 1) AS root_9,
    (SELECT string_agg(name || '=' || coalesce(CAST(field_id AS VARCHAR), 'none') || ' ' || coalesce(repetition_type, 'none'), ', ') FROM (SELECT * FROM parquet_schema('db/emptied/data/00000000-0000-7000-8000-000000000009-0.parquet') OFFSET 1)) AS leaves_9
) TO 'emptied.check.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
