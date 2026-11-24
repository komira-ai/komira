-- order: query
-- NaN ties, inf, then finite values
SELECT d FROM T ORDER BY d DESC NULLS LAST LIMIT 5 OFFSET 1
