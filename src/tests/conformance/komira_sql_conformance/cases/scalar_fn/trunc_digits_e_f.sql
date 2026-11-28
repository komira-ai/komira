-- order: rows
SELECT k, trunc(f, 1) AS t1, trunc(f, -1) AS tm1, trunc(f, 400) AS t400, trunc(f, -400) AS tm400 FROM E
