-- order: rows
-- pass filter all over a BOOLEAN column, nulls rows
SELECT k, g, v FROM t_nulls WHERE k > 2
