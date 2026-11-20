-- order: rows
-- join anti over a BIGINT column, allnull rows
SELECT k, g, v FROM t_allnull WHERE k NOT IN (SELECT g FROM t_allnull)
