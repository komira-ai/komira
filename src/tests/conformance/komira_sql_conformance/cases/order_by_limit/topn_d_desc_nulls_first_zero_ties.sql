-- order: query
-- range holds both 0.0 rows and the next value
SELECT d FROM T ORDER BY d DESC NULLS FIRST LIMIT 3 OFFSET 8
