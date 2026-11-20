-- order: rows
-- bt in a case result
SELECT k, CASE WHEN k < 3 THEN bt ELSE false END AS z FROM T
