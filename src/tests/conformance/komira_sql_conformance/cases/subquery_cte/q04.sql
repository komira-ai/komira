-- order: rows
-- scalar subquery over the same table the outer query reads
SELECT k FROM T WHERE v > (SELECT avg(v) FROM T)
