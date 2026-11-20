-- order: query
SELECT t, COUNT(*) AS c FROM T WHERE NOT (s LIKE '%z') GROUP BY t HAVING COUNT(*) > 1 ORDER BY t
