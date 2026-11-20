-- order: rows
SELECT k FROM T WHERE k < (SELECT count(n) FROM T)
