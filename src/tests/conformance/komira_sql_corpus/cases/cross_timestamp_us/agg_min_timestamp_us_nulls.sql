-- order: rows
-- agg min over a TIMESTAMP column, nulls rows
SELECT g, min(v) AS m FROM t_nulls GROUP BY g
