-- order: query
-- the range ends in the NULLs
SELECT a FROM T ORDER BY a DESC NULLS LAST LIMIT 4 OFFSET 7
