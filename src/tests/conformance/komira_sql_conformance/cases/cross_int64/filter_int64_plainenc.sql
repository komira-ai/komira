-- order: rows
-- filter over a BIGINT column; same rows as t_full
SELECT k, g, v FROM t_full WHERE v > 30
