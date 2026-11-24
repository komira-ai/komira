-- order: query
-- LIMIT 0 with an offset is no row
SELECT a FROM T ORDER BY a ASC NULLS LAST LIMIT 0 OFFSET 2
