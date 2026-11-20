-- order: rows
-- agg count 0key over a TIMESTAMP column, nulls rows
SELECT count(*) AS c FROM t_nulls
