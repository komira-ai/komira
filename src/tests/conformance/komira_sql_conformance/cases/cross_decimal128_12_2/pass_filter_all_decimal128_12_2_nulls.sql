-- order: rows
-- pass filter all over a DECIMAL(12,2) column, nulls rows
SELECT k, g, v FROM t_nulls WHERE k > 2
