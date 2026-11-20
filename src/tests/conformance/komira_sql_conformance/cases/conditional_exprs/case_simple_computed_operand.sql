-- order: rows
SELECT k, CASE a + 1 WHEN 1 THEN 'p1' WHEN 3 THEN 'p3' ELSE 'other' END AS z FROM T
