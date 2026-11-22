-- order: rows
-- union over a DECIMAL(12,2) column, single rows
SELECT k, g, v FROM t_single UNION ALL SELECT k, g, v FROM t_single
