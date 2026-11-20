-- order: rows
-- agg min over a DECIMAL(12,2) column, empty rows
SELECT g, min(v) AS m FROM t_empty GROUP BY g
