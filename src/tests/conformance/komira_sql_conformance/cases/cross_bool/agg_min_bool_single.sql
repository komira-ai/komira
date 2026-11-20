-- order: rows
-- agg min over a BOOLEAN column, single rows
SELECT g, min(v) AS m FROM t_single GROUP BY g
