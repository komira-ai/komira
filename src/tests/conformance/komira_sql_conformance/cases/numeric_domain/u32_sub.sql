-- order: rows
-- only the rows the expression answers; the others raise an error
SELECT k, u32a - u32b AS y FROM T WHERE k IN (0, 1, 2, 5, 7, 8, 9, 10, 11, 12)
