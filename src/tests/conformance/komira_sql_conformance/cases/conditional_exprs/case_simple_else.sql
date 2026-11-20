-- order: rows
SELECT k, CASE a WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'many' END AS z FROM T
