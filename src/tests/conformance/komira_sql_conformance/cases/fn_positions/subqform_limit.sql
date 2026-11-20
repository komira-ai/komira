-- order: rows
-- the same subquery with an explicit limit 1
SELECT k, (SELECT w FROM U WHERE j = 2 ORDER BY w ASC NULLS FIRST LIMIT 1) AS z FROM T
