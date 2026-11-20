-- order: rows
-- agg max over a DECIMAL(12,2) column, nulls rows
SELECT g, max(v) AS m FROM t_nulls GROUP BY g
