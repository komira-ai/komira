-- order: rows
-- agg max over a DECIMAL(12,2) column, full rows
SELECT g, max(v) AS m FROM t_full GROUP BY g
