-- order: rows
SELECT k, date_part('isodow', ts) AS z FROM T
