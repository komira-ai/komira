-- order: query
-- sort desc over a TIMESTAMPTZ column, full rows
SELECT k, g, v FROM t_full ORDER BY v DESC
