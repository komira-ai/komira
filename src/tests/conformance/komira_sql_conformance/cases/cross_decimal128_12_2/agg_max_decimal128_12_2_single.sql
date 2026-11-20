-- order: rows
-- agg max over a DECIMAL(12,2) column, single rows
SELECT g, max(v) AS m FROM t_single GROUP BY g
