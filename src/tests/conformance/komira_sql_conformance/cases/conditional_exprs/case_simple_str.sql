-- order: rows
SELECT k, CASE s WHEN 'a' THEN 1 WHEN '' THEN 2 ELSE 3 END AS z FROM T
