-- order: rows
SELECT k, IFNULL(LEAST(a, b), -99) AS z FROM T
