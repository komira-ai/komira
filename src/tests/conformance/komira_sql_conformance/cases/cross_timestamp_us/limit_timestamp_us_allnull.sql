-- order: query
-- limit over a TIMESTAMP column, allnull rows
SELECT k, g, v FROM t_allnull ORDER BY k ASC NULLS LAST LIMIT 3
