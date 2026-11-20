-- order: rows
SELECT k, date_part('quarter', ts) AS z FROM T
