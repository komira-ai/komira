-- order: query
-- text in byte order, offset past the empty string and the leading space
SELECT s FROM T ORDER BY s ASC NULLS LAST LIMIT 3 OFFSET 2
