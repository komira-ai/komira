-- order: query
-- topn over a DECIMAL(12,2) column, full rows
SELECT k, g, v FROM t_full ORDER BY v DESC LIMIT 3
