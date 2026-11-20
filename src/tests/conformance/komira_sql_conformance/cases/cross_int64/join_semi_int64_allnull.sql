-- order: rows
-- join semi over a BIGINT column, allnull rows
SELECT k, g, v FROM t_allnull WHERE k IN (SELECT g FROM t_allnull)
