-- order: rows
-- filter over a VARCHAR column, single rows
SELECT k, g, v FROM t_single WHERE v > 'c'
