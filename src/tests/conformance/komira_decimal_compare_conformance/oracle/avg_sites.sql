-- avg_sites.tsv: DuckDB's own avg() for each query of the AVG site tests (one row per
-- group): the query's name, its text, the group k and the answer
-- printed as printf('%.17e'), eighteen significant digits, which read back to the same
-- double. avg() of a DECIMAL(38, s) and of a BIGINT divides in 80-bit long double.
COPY (
SELECT name, query, k, dbl FROM (
  SELECT 0 AS n, 'avg_decimal_scale0' AS name, 'select k, avg(d0) as x from pd group by k' AS query, k, printf('%.17e', x) AS dbl FROM (select k, x from (select k, avg(d0) as x from pd group by k))
  UNION ALL
  SELECT 1 AS n, 'avg_decimal_scale2' AS name, 'select k, avg(d2) as x from pd group by k' AS query, k, printf('%.17e', x) AS dbl FROM (select k, avg(d2) as x from pd group by k)
  UNION ALL
  SELECT 2 AS n, 'avg_decimal_scale10' AS name, 'select k, avg(d10) as x from pd group by k' AS query, k, printf('%.17e', x) AS dbl FROM (select k, avg(d10) as x from pd group by k)
  UNION ALL
  SELECT 3 AS n, 'avg_bigint_13_groups' AS name, 'select k, avg(v) as x from pj group by k' AS query, k, printf('%.17e', x) AS dbl FROM (select k, avg(v) as x from pj group by k)
  UNION ALL
  SELECT 4 AS n, 'avg_bigint_23_groups' AS name, 'select k, avg(v) as x from pa group by k' AS query, k, printf('%.17e', x) AS dbl FROM (select k, avg(v) as x from pa group by k)
  UNION ALL
  SELECT 5 AS n, 'avg_bigint_one_row' AS name, 'select min(k) as k, avg(v) as x from pa where k = 7' AS query, k, printf('%.17e', x) AS dbl FROM (select min(k) as k, avg(v) as x from pa where k = 7)
  UNION ALL
  SELECT 6 AS n, 'avg_bigint_one_row_10' AS name, 'select min(k) as k, avg(v) as x from pa where k = 10' AS query, k, printf('%.17e', x) AS dbl FROM (select min(k) as k, avg(v) as x from pa where k = 10)
) AS q ORDER BY n, k, dbl
) TO 'avg_sites.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
