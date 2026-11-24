-- order: query
-- cut inside the NaN ties after the NULLs
SELECT d FROM T ORDER BY d DESC NULLS FIRST LIMIT 2 OFFSET 1
