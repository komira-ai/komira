-- order: rows
-- agg cd with count over a TIMESTAMP column, single rows
SELECT count(*) AS c, count(DISTINCT v) AS n FROM t_single
