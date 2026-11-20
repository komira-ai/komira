-- order: rows
SELECT k, date_part('decade', ts) AS z FROM T
