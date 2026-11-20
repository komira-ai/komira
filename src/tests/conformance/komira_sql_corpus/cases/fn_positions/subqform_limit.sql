-- order: rows
-- the same subquery with an explicit limit 1
SELECT k, (SELECT w FROM U WHERE j = 2 LIMIT 1) AS z FROM T
