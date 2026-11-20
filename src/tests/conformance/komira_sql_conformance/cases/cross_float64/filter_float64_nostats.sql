-- order: rows
-- filter over a DOUBLE column; same rows as t_full
SELECT k, g, v FROM t_full WHERE v > 3.5
