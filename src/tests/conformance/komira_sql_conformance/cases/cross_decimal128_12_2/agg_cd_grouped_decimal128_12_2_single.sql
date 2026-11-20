-- order: rows
-- agg cd grouped over a DECIMAL(12,2) column, single rows
SELECT g, count(DISTINCT v) AS n FROM t_single GROUP BY g
