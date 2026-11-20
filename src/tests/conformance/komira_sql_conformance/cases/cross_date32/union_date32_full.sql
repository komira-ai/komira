-- order: rows
-- union over a DATE column, full rows
SELECT k, g, v FROM t_full UNION ALL SELECT k, g, v FROM t_full
