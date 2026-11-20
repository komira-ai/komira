-- order: rows
-- filter over a VARCHAR column, full rows
SELECT k, g, v FROM t_full WHERE v > 'c'
