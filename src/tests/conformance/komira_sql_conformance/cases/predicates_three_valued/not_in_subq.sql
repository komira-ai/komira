-- order: rows
SELECT k FROM T WHERE i NOT IN (SELECT v FROM S)
