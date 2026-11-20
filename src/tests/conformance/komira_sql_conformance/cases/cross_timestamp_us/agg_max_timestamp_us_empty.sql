-- order: rows
-- agg max over a TIMESTAMP column, empty rows
SELECT g, max(v) AS m FROM t_empty GROUP BY g
