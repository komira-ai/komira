-- order: rows
-- union over a BOOLEAN column, single rows
SELECT k, g, v FROM t_single UNION ALL SELECT k, g, v FROM t_single
