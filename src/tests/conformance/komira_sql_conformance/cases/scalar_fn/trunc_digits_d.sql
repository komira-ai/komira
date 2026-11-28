-- order: rows
SELECT k, trunc(d, 1) AS t1, trunc(d, -1) AS tm1, trunc(CAST(d AS FLOAT), 1) AS tf FROM T
