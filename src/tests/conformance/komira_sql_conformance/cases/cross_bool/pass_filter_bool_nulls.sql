-- order: rows
-- pass filter over a BOOLEAN column, nulls rows
SELECT v FROM t_nulls WHERE k > 2
