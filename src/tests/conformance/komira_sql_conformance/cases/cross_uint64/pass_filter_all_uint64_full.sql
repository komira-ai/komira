-- order: rows
-- pass filter all over a UBIGINT column, full rows
SELECT k, g, v FROM t_full WHERE k > 2
