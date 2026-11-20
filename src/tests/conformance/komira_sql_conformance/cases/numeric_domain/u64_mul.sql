-- order: rows
-- only the rows the expression answers; the others raise an error
SELECT k, u64a * u64b AS y FROM T WHERE k IN (0, 1, 2, 3, 4, 5, 9, 10, 11, 12)
