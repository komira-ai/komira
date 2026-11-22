-- order: rows
-- agg cd grouped over a TIMESTAMP column, full rows
SELECT g, count(DISTINCT v) AS n FROM t_full GROUP BY g
