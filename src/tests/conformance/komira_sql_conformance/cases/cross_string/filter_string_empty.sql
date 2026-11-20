-- order: rows
-- filter over a VARCHAR column, empty rows
SELECT k, g, v FROM t_empty WHERE v > 'c'
