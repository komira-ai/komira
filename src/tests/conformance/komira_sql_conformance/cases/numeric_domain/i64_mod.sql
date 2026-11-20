-- order: rows
-- only the rows the expression answers; the others raise an error
SELECT k, mod(i64a, i64b) AS y FROM T WHERE k IN (0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12)
