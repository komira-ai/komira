-- order: rows
SELECT k, date_part('week', ts) AS z FROM T
