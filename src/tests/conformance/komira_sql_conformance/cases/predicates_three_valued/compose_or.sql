-- order: rows
SELECT k, ((i BETWEEN 2 AND 5) OR (s LIKE 'a%')) AS z FROM T
