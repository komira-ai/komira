-- order: rows
-- join anti over a DECIMAL(12,2) column, allnull rows
SELECT k, g, v FROM t_allnull WHERE k NOT IN (SELECT g FROM t_allnull)
