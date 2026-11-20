-- order: rows
-- agg min over a DECIMAL(12,2) column, single rows
SELECT g, min(v) AS m FROM t_single GROUP BY g
