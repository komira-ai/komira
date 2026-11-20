-- order: query
-- limit over a BIGINT column, empty rows
SELECT k, g, v FROM t_empty ORDER BY k ASC NULLS LAST LIMIT 3
