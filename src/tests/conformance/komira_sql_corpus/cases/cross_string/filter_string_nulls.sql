-- order: rows
-- filter over a VARCHAR column, nulls rows
SELECT k, g, v FROM t_nulls WHERE v > 'c'
