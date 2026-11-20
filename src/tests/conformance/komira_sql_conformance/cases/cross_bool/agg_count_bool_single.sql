-- order: rows
-- agg count over a BOOLEAN column, single rows
SELECT v, count(*) AS n FROM t_single GROUP BY v
