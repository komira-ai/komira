-- order: rows
-- agg var 0key over a BIGINT column, nulls rows
SELECT var_samp(v) AS s FROM t_nulls
