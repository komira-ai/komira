-- order: rows
-- filter project over a TIMESTAMP column, empty rows
SELECT v FROM t_empty WHERE v > TIMESTAMP '2024-01-01 03:30:15.123456'
