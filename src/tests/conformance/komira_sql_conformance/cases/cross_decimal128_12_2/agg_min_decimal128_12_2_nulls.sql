-- order: rows
-- agg min over a DECIMAL(12,2) column, nulls rows
SELECT g, min(v) AS m FROM t_nulls GROUP BY g
