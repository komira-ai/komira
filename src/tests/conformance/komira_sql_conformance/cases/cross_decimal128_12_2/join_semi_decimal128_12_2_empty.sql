-- order: rows
-- join semi over a DECIMAL(12,2) column, empty rows
SELECT k, g, v FROM t_empty WHERE k IN (SELECT g FROM t_empty)
