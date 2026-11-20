-- order: rows
-- only the rows the expression answers; the others raise an error
SELECT k, sqrt(f64) AS y FROM T WHERE k IN (0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12)
