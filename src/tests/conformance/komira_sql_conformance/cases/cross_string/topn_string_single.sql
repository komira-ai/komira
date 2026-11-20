-- order: query
-- topn over a VARCHAR column, single rows
SELECT k, g, v FROM t_single ORDER BY v DESC LIMIT 3
