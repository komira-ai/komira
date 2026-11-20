-- order: rows
-- agg median 0key over a BOOLEAN column, nulls rows
SELECT median(v) AS m FROM t_nulls
