-- order: query
-- offset and cut both inside runs of ties
SELECT a FROM T ORDER BY a DESC NULLS FIRST LIMIT 3 OFFSET 4
