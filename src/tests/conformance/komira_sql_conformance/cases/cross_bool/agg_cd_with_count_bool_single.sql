-- order: rows
-- agg cd with count over a BOOLEAN column, single rows
SELECT count(*) AS c, count(DISTINCT v) AS n FROM t_single
