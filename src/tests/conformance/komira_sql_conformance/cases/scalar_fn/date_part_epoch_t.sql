-- order: rows
SELECT k, date_part('epoch', t) AS s, extract(epoch FROM v) AS v FROM T
