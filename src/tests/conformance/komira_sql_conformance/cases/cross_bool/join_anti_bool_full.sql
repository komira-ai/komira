-- order: rows
-- join anti over a BOOLEAN column, full rows
SELECT k, g, v FROM t_full WHERE k NOT IN (SELECT g FROM t_full)
