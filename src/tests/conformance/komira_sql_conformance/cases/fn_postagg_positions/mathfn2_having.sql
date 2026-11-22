-- order: rows
-- pow(n, 2) on a group key in having
SELECT n AS z FROM T GROUP BY n HAVING pow(n, 2) > 4.0
