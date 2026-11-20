-- order: rows
-- union over a INTEGER column, full rows
SELECT k, g, v FROM t_full UNION ALL SELECT k, g, v FROM t_full
