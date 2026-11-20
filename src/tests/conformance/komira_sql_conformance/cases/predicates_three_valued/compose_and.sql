-- order: rows
SELECT k, ((i BETWEEN 2 AND 5) AND (s LIKE 'a%')) AS z FROM T
