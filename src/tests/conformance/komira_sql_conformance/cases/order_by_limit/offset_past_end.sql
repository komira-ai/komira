-- order: query
-- OFFSET beyond the last row gives no rows
SELECT a, b, k FROM T ORDER BY a, b, k LIMIT 3 OFFSET 99
