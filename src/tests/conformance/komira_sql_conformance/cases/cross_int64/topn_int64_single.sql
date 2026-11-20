-- order: query
-- topn over a BIGINT column, single rows
SELECT k, g, v FROM t_single ORDER BY v DESC LIMIT 3
