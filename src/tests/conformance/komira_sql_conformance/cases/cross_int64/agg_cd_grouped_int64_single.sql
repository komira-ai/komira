-- order: rows
-- agg cd grouped over a BIGINT column, single rows
SELECT g, count(DISTINCT v) AS n FROM t_single GROUP BY g
