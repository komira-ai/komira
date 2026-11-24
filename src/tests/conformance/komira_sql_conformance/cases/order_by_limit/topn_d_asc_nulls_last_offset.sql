-- order: query
-- NaN sorts above inf; offset into inf and NaN ties
SELECT d FROM T ORDER BY d ASC NULLS LAST LIMIT 4 OFFSET 6
