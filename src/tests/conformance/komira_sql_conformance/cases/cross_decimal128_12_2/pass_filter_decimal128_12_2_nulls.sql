-- order: rows
-- pass filter over a DECIMAL(12,2) column, nulls rows
SELECT v FROM t_nulls WHERE k > 2
