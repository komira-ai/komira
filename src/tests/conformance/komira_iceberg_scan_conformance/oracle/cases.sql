-- The cases of the Iceberg scan conformance. Each line is one case: DuckDB
-- (with its avro and iceberg extensions) runs the query over the table
-- `orders` and writes the answer to <case>.tsv; tests/test_iceberg_scan_parity
-- runs the same query through run_sql, with 'orders' replaced by the path of
-- the staged table, and compares the rows. `allow_moved_paths = true`: the
-- manifests record file:///warehouse/db/orders, which is not where the files
-- are. The snapshots are 6000000001 to 6000000006 (the sixth is current): two
-- appends, a position delete, an equality delete, an append, an overwrite.
-- One query per line, ending in `TO '<case>.tsv' (...);`.
COPY (SELECT * FROM iceberg_scan('orders', allow_moved_paths = true) ORDER BY order_id) TO 'full_scan.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, note FROM iceberg_scan('orders', allow_moved_paths = true) ORDER BY order_id) TO 'projection.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT count(*) AS n FROM iceberg_scan('orders', allow_moved_paths = true)) TO 'count_all.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, qty, region FROM iceberg_scan('orders', allow_moved_paths = true) WHERE region = 'east' ORDER BY order_id) TO 'partition_equals.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, region FROM iceberg_scan('orders', allow_moved_paths = true) WHERE region = 'south' ORDER BY order_id) TO 'partition_no_match.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, qty FROM iceberg_scan('orders', allow_moved_paths = true) WHERE qty > 100 ORDER BY order_id) TO 'bound_greater.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, qty FROM iceberg_scan('orders', allow_moved_paths = true) WHERE qty >= 15 AND qty < 60 ORDER BY order_id) TO 'bound_range.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, ship_date FROM iceberg_scan('orders', allow_moved_paths = true) WHERE ship_date >= DATE '2027-04-01' AND ship_date < DATE '2027-06-01' ORDER BY order_id) TO 'date_range.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, note FROM iceberg_scan('orders', allow_moved_paths = true) WHERE note IS NULL ORDER BY order_id) TO 'is_null.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, note FROM iceberg_scan('orders', allow_moved_paths = true) WHERE note IS NOT NULL ORDER BY order_id) TO 'is_not_null.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, price FROM iceberg_scan('orders', allow_moved_paths = true) WHERE price > 1000 ORDER BY order_id) TO 'double_nan_greater.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, price FROM iceberg_scan('orders', allow_moved_paths = true) WHERE price >= 2 AND price <= 10 ORDER BY order_id) TO 'double_range.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, paid FROM iceberg_scan('orders', allow_moved_paths = true) WHERE paid = true ORDER BY order_id) TO 'boolean_equals.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT region, count(*) AS n, sum(qty) AS total_qty, min(order_id) AS first_id, max(ship_date) AS last_ship FROM iceberg_scan('orders', allow_moved_paths = true) GROUP BY region ORDER BY region) TO 'aggregate_by_region.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT count(*) AS n, count(note) AS notes, sum(qty) AS total_qty, min(order_id) AS first_id, max(order_id) AS last_id FROM iceberg_scan('orders', allow_moved_paths = true)) TO 'aggregate_total.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM iceberg_scan('orders', allow_moved_paths = true, snapshot_from_id = 6000000002) ORDER BY order_id) TO 'snapshot_two.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id, qty, note FROM iceberg_scan('orders', allow_moved_paths = true, snapshot_from_id = 6000000001) WHERE region = 'west' ORDER BY order_id) TO 'snapshot_one_west.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT order_id FROM iceberg_scan('orders', allow_moved_paths = true, snapshot_from_id = 6000000003) ORDER BY order_id) TO 'snapshot_three_ids.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT region, count(*) AS n FROM iceberg_scan('orders', allow_moved_paths = true, snapshot_from_id = 6000000005) GROUP BY region ORDER BY region) TO 'snapshot_five_by_region.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
