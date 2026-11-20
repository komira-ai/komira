-- order: query
-- sort over a DECIMAL(12,2) column, allnull rows
SELECT k, g, v FROM t_allnull ORDER BY v
