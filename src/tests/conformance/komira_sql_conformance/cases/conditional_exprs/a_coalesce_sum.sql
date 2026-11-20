-- order: rows
SELECT sum(COALESCE(a, 0)) AS z FROM T
