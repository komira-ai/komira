-- order: rows
-- limit over a TIMESTAMPTZ column, full rows
SELECT k, g, v FROM t_full LIMIT 3
