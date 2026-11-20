-- order: rows
-- filter over a TINYINT column, full rows
SELECT k, g, v FROM t_full WHERE v > 0
