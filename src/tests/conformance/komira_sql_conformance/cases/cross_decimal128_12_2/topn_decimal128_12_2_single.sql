-- order: query
-- topn over a DECIMAL(12,2) column, single rows
SELECT k, g, v FROM t_single ORDER BY v DESC LIMIT 3
