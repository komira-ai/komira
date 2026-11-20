-- order: rows
-- agg sum 0key over a BIGINT column, nulls rows
SELECT sum(v) AS s FROM t_nulls
