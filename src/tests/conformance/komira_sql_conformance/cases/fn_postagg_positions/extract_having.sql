-- order: rows
-- month(t) on a group key in having
SELECT t AS z FROM T GROUP BY t HAVING month(t) > 5
