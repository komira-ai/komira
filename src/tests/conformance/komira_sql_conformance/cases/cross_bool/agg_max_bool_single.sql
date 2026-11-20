-- order: rows
-- agg max over a BOOLEAN column, single rows
SELECT g, max(v) AS m FROM t_single GROUP BY g
