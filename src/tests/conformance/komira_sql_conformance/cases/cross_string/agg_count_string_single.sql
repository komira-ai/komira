-- order: rows
-- agg count over a VARCHAR column, single rows
SELECT v, count(*) AS n FROM t_single GROUP BY v
