-- answers.tsv: DuckDB's answer to each query of the multi-file scan tests, one row
-- per result row: the block's name, the query text the test runs through
-- run_sql (the blocks g_* are read through SQL text the test builds itself, since
-- it holds the file paths), the row's position and the row as its cells
-- joined by '|' (a DATE as its days since 1970-01-01, a DECIMAL as DuckDB casts
-- it, a count and a sum as integers). dir3, dir02, hv and hv_off are views
-- over the staged files: the three files of the directory, two of them, the
-- four leaf files of the Hive tree read with hive_partitioning = true, and the
-- same four read with it off. schema_* hold the column names and types of
-- SELECT * (DuckDB's own names for the types) and types_hv typeof() of the
-- partition columns.
CREATE VIEW dir3 AS SELECT * FROM read_parquet(['dir3/part-0.parquet', 'dir3/part-1.parquet', 'dir3/part-2.parquet']);
CREATE VIEW dir02 AS SELECT * FROM read_parquet(['dir3/part-0.parquet', 'dir3/part-2.parquet']);
CREATE VIEW hv AS SELECT * FROM read_parquet([
  'hive/yr=2024/tag=red/dt=2024-01-01/part-0.parquet',
  'hive/yr=2024/tag=blue/dt=2024-01-02/part-0.parquet',
  'hive/yr=2025/tag=red/dt=2024-01-01/part-0.parquet',
  'hive/yr=2025/tag=blue/dt=2024-03-05/part-0.parquet'
], hive_partitioning = true);
CREATE VIEW hv_off AS SELECT * FROM read_parquet([
  'hive/yr=2024/tag=red/dt=2024-01-01/part-0.parquet',
  'hive/yr=2024/tag=blue/dt=2024-01-02/part-0.parquet',
  'hive/yr=2025/tag=red/dt=2024-01-01/part-0.parquet',
  'hive/yr=2025/tag=blue/dt=2024-03-05/part-0.parquet'
], hive_partitioning = false);
COPY (
SELECT q, query, pos, line FROM (
  SELECT 'd_all' AS q, 'select * from dir3 order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, g::VARCHAR, v::VARCHAR, s) AS line FROM (select * from dir3 order by id)
  UNION ALL
  SELECT 'd_count' AS q, 'select count(*) as n from dir3' AS query, row_number() OVER (ORDER BY n) AS pos, concat_ws('|', n::VARCHAR) AS line FROM (select count(*) as n from dir3)
  UNION ALL
  SELECT 'd_group' AS q, 'select g, count(*) as n, sum(id) as t from dir3 group by g order by g' AS query, row_number() OVER (ORDER BY g) AS pos, concat_ws('|', g::VARCHAR, n::VARCHAR, t::VARCHAR) AS line FROM (select g, count(*) as n, sum(id) as t from dir3 group by g order by g)
  UNION ALL
  SELECT 'd_filter' AS q, 'select id, s from dir3 where g = 2 order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, s) AS line FROM (select id, s from dir3 where g = 2 order by id)
  UNION ALL
  SELECT 'd_str_group' AS q, 'select s, sum(v) as t from dir3 group by s order by s' AS query, row_number() OVER (ORDER BY s) AS pos, concat_ws('|', s, t::VARCHAR) AS line FROM (select s, sum(v) as t from dir3 group by s order by s)
  UNION ALL
  SELECT 'd_limit' AS q, 'select id, v from dir3 where id > 5 order by id desc limit 3' AS query, row_number() OVER (ORDER BY id DESC) AS pos, concat_ws('|', id::VARCHAR, v::VARCHAR) AS line FROM (select id, v from dir3 where id > 5 order by id desc limit 3)
  UNION ALL
  SELECT 'd_project' AS q, 'select s from dir3 order by s' AS query, row_number() OVER (ORDER BY s) AS pos, concat_ws('|', s) AS line FROM (select s from dir3 order by s)
  UNION ALL
  SELECT 'h_all' AS q, 'select * from hv order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, v::VARCHAR, s, (dt - DATE '1970-01-01')::VARCHAR, tag, yr::VARCHAR) AS line FROM (select * from hv order by id)
  UNION ALL
  SELECT 'h_count' AS q, 'select count(*) as n from hv' AS query, row_number() OVER (ORDER BY n) AS pos, concat_ws('|', n::VARCHAR) AS line FROM (select count(*) as n from hv)
  UNION ALL
  SELECT 'h_prune_int' AS q, 'select id, yr from hv where yr = 2025 order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, yr::VARCHAR) AS line FROM (select id, yr from hv where yr = 2025 order by id)
  UNION ALL
  SELECT 'h_prune_str' AS q, 'select id, tag from hv where tag = ''red'' order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, tag) AS line FROM (select id, tag from hv where tag = 'red' order by id)
  UNION ALL
  SELECT 'h_prune_date' AS q, 'select id, dt from hv where dt >= date ''2024-01-02'' order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, (dt - DATE '1970-01-01')::VARCHAR) AS line FROM (select id, dt from hv where dt >= date '2024-01-02' order by id)
  UNION ALL
  SELECT 'h_data' AS q, 'select id, yr from hv where v >= 500.00 order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, yr::VARCHAR) AS line FROM (select id, yr from hv where v >= 500.00 order by id)
  UNION ALL
  SELECT 'h_both' AS q, 'select id, yr, tag, v from hv where yr = 2024 and v >= 500.00 order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, yr::VARCHAR, tag, v::VARCHAR) AS line FROM (select id, yr, tag, v from hv where yr = 2024 and v >= 500.00 order by id)
  UNION ALL
  SELECT 'h_only_part' AS q, 'select tag from hv order by tag' AS query, row_number() OVER (ORDER BY tag) AS pos, concat_ws('|', tag) AS line FROM (select tag from hv order by tag)
  UNION ALL
  SELECT 'h_group_int' AS q, 'select yr, count(*) as n, sum(id) as t from hv group by yr order by yr' AS query, row_number() OVER (ORDER BY yr) AS pos, concat_ws('|', yr::VARCHAR, n::VARCHAR, t::VARCHAR) AS line FROM (select yr, count(*) as n, sum(id) as t from hv group by yr order by yr)
  UNION ALL
  SELECT 'h_group_str' AS q, 'select tag, count(*) as n from hv group by tag order by tag' AS query, row_number() OVER (ORDER BY tag) AS pos, concat_ws('|', tag, n::VARCHAR) AS line FROM (select tag, count(*) as n from hv group by tag order by tag)
  UNION ALL
  SELECT 'h_limit' AS q, 'select dt, tag, yr, id from hv order by id desc limit 4' AS query, row_number() OVER (ORDER BY id DESC) AS pos, concat_ws('|', (dt - DATE '1970-01-01')::VARCHAR, tag, yr::VARCHAR, id::VARCHAR) AS line FROM (select dt, tag, yr, id from hv order by id desc limit 4)
  UNION ALL
  SELECT 'h_pruned_to_nothing' AS q, 'select count(*) as n from hv where yr = 1999' AS query, row_number() OVER (ORDER BY n) AS pos, concat_ws('|', n::VARCHAR) AS line FROM (select count(*) as n from hv where yr = 1999)
  UNION ALL
  SELECT 'g_all' AS q, 'select id, g from dir3 order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, g::VARCHAR) AS line FROM (select id, g from dir3 order by id)
  UNION ALL
  SELECT 'g_from' AS q, 'select count(*) as n from dir3' AS query, row_number() OVER (ORDER BY n) AS pos, concat_ws('|', n::VARCHAR) AS line FROM (select count(*) as n from dir3)
  UNION ALL
  SELECT 'g_brace' AS q, 'select id, s from dir02 order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, s) AS line FROM (select id, s from dir02 order by id)
  UNION ALL
  SELECT 'g_hive' AS q, 'select id, dt, tag, yr from hv order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, (dt - DATE '1970-01-01')::VARCHAR, tag, yr::VARCHAR) AS line FROM (select id, dt, tag, yr from hv order by id)
  UNION ALL
  SELECT 'g_hive_off' AS q, 'select * from hv_off order by id' AS query, row_number() OVER (ORDER BY id) AS pos, concat_ws('|', id::VARCHAR, v::VARCHAR, s) AS line FROM (select * from hv_off order by id)
  UNION ALL
  SELECT 'schema_dir3' AS q, '' AS query, row_number() OVER () AS pos, concat_ws('|', column_name, column_type) AS line FROM (DESCRIBE SELECT * FROM dir3)
  UNION ALL
  SELECT 'schema_hv' AS q, '' AS query, row_number() OVER () AS pos, concat_ws('|', column_name, column_type) AS line FROM (DESCRIBE SELECT * FROM hv)
  UNION ALL
  (SELECT 'types_hv' AS q, '' AS query, 1 AS pos, concat_ws('|', typeof(dt), typeof(tag), typeof(yr)) AS line FROM hv LIMIT 1)
) AS a ORDER BY q, pos
) TO 'answers.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
