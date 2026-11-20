-- order: rows
-- filter project over a VARCHAR column, nulls rows
SELECT v FROM t_nulls WHERE v > 'c'
