-- order: rows
SELECT k, date_part('dayofweek', ts) AS z FROM T
