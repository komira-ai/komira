-- order: rows
-- union over a DECIMAL(12,2) column, full rows
SELECT k, g, v FROM t_full UNION ALL SELECT k, g, v FROM t_full
