-- order: rows
-- agg count 0key over a VARCHAR column, nulls rows
SELECT count(*) AS c FROM t_nulls
