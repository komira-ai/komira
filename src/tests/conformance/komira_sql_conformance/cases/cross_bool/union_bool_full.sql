-- order: rows
-- union over a BOOLEAN column, full rows
SELECT k, g, v FROM t_full UNION ALL SELECT k, g, v FROM t_full
