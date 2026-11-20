-- order: rows
-- union over a FLOAT column, full rows
SELECT k, g, v FROM t_full UNION ALL SELECT k, g, v FROM t_full
