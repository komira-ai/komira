-- order: query
-- NULLs, -inf, then finite values
SELECT d FROM T ORDER BY d ASC NULLS FIRST LIMIT 5
