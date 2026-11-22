-- order: query
SELECT t, COUNT(*) AS c FROM T WHERE NOT (s LIKE 'z%') GROUP BY t ORDER BY t
