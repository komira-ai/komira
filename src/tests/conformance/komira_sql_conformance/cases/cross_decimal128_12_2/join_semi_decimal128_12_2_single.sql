-- order: rows
-- join semi over a DECIMAL(12,2) column, single rows
SELECT k, g, v FROM t_single WHERE k IN (SELECT g FROM t_single)
