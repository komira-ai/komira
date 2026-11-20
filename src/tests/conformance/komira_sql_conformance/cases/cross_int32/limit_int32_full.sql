-- order: query
-- limit over a INTEGER column, full rows
SELECT k, g, v FROM t_full ORDER BY k ASC NULLS LAST LIMIT 3
