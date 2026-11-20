-- order: rows
-- agg max over a TIMESTAMP column, nulls rows
SELECT g, max(v) AS m FROM t_nulls GROUP BY g
