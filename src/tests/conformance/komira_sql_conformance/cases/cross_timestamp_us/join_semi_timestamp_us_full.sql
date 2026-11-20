-- order: rows
-- join semi over a TIMESTAMP column, full rows
SELECT k, g, v FROM t_full WHERE k IN (SELECT g FROM t_full)
