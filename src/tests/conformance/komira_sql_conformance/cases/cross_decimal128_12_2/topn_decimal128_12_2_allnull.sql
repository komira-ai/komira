-- order: query
-- topn over a DECIMAL(12,2) column, allnull rows
SELECT k, g, v FROM t_allnull ORDER BY v DESC LIMIT 3
