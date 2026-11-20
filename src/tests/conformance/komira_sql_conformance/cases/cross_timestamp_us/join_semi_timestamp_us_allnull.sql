-- order: rows
-- join semi over a TIMESTAMP column, allnull rows
SELECT k, g, v FROM t_allnull WHERE k IN (SELECT g FROM t_allnull)
