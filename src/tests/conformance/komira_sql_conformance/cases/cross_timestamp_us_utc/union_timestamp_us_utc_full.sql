-- order: rows
-- union over a TIMESTAMPTZ column, full rows
SELECT k, g, v FROM t_full UNION ALL SELECT k, g, v FROM t_full
