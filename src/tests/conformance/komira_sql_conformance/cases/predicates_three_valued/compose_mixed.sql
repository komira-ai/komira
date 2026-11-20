-- order: rows
SELECT k, ((i IN (2, 3, 4)) OR (s NOT LIKE 'a%')) AS z FROM T
