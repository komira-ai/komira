-- order: rows
SELECT k, a FROM T WHERE IFNULL(a, -1) < 0
