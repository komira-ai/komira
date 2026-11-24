-- order: query
-- the empty string and the NULL at the end
SELECT s FROM T ORDER BY s DESC NULLS LAST LIMIT 2 OFFSET 10
