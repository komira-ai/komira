-- order: rows
-- pass filter all over a BIGINT column, empty rows
SELECT k, g, v FROM t_empty WHERE k > 2
