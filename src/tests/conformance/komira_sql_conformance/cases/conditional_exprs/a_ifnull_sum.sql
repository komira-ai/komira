-- order: rows
SELECT sum(IFNULL(a, -1)) AS z FROM T
