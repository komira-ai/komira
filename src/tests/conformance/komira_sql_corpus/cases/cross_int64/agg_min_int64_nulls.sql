-- order: rows
-- agg min over a BIGINT column, nulls rows
SELECT g, min(v) AS m FROM t_nulls GROUP BY g
