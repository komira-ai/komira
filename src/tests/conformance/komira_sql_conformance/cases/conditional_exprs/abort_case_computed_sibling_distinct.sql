-- order: rows
SELECT k, a + 1 AS p, CASE WHEN b + 2 > 3 THEN 1 ELSE 0 END AS c FROM T
