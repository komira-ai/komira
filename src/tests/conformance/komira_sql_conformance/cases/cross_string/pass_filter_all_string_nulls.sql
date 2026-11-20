-- order: rows
-- pass filter all over a VARCHAR column, nulls rows
SELECT k, g, v FROM t_nulls WHERE k > 2
