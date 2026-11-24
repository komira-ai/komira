-- order: query
-- three text values with ties; offset and cut inside runs
SELECT c FROM T ORDER BY c ASC NULLS LAST LIMIT 6 OFFSET 2
