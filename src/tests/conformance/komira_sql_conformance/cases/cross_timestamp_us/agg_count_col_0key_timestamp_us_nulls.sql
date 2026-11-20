-- order: rows
-- agg count col 0key over a TIMESTAMP column, nulls rows
SELECT count(v) AS c FROM t_nulls
