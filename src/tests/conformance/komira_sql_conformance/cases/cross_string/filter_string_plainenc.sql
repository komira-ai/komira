-- order: rows
-- filter over a VARCHAR column; same rows as t_full
SELECT k, g, v FROM t_full WHERE v > 'c'
