-- order: query
-- topn over a BIGINT column, allnull rows
SELECT k, g, v FROM t_allnull ORDER BY v DESC LIMIT 3
