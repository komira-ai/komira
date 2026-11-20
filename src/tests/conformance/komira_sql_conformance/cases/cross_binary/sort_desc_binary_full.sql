-- order: query
-- sort desc over a BLOB column, full rows
SELECT k, g, v FROM t_full ORDER BY v DESC
