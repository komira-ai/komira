-- order: rows
SELECT k, CASE WHEN a + 1 > 3 THEN 1 ELSE 0 END AS c FROM T
