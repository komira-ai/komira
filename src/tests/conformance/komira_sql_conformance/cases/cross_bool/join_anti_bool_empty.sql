-- order: rows
-- join anti over a BOOLEAN column, empty rows
SELECT k, g, v FROM t_empty WHERE k NOT IN (SELECT g FROM t_empty)
