-- order: query
-- limit over a DECIMAL(12,2) column, single rows
SELECT k, g, v FROM t_single ORDER BY k ASC NULLS LAST LIMIT 3
