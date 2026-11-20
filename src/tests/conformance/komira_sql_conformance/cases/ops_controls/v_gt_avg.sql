-- order: rows
SELECT k FROM T WHERE v > (SELECT avg(v) FROM T)
