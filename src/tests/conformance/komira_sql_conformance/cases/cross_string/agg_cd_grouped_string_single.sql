-- order: rows
-- agg cd grouped over a VARCHAR column, single rows
SELECT g, count(DISTINCT v) AS n FROM t_single GROUP BY g
