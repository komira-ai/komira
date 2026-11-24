-- order: query
-- total order (x DESC NULLS LAST, k)
SELECT x, k FROM U ORDER BY x DESC NULLS LAST, k LIMIT 30 OFFSET 15000
