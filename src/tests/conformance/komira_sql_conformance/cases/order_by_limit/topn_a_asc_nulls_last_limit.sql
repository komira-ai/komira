-- order: query
-- top-N with ties at the cut, NULLs last
SELECT a FROM T ORDER BY a ASC NULLS LAST LIMIT 5
