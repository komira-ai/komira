-- order: rows
-- filter over a BIGINT column, empty rows
SELECT k, g, v FROM t_empty WHERE v > 30
