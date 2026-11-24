-- order: query
-- NULLs first, offset into the NULLs, ties at the cut
SELECT a FROM T ORDER BY a ASC NULLS FIRST LIMIT 4 OFFSET 1
