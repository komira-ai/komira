-- order: query
-- sort desc over a BOOLEAN column, allnull rows
SELECT k, g, v FROM t_allnull ORDER BY v DESC
