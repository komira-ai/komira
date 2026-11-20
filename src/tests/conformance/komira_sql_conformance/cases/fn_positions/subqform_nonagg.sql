-- order: rows
-- uncorrelated 1-row scalar subquery in the select list
SELECT k, (SELECT w FROM U WHERE j = 2) AS z FROM T
