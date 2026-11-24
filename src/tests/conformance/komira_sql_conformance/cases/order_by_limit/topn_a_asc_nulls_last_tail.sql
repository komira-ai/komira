-- order: query
-- the range is the last rows, past the last value into NULLs, limit past the end
SELECT a FROM T ORDER BY a ASC NULLS LAST LIMIT 5 OFFSET 9
