-- order: rows
-- multiply(k, 3) on a group key in having
SELECT k AS z FROM T GROUP BY k HAVING multiply(k, 3) > 9
