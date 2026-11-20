-- order: rows
-- agg max over a DECIMAL(12,2) column, empty rows
SELECT g, max(v) AS m FROM t_empty GROUP BY g
