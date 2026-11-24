-- order: query
-- non-ASCII and lower case first
SELECT s FROM T ORDER BY s DESC NULLS FIRST LIMIT 4 OFFSET 1
