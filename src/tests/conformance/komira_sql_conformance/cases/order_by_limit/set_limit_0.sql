-- order: rows
-- LIMIT with no ORDER BY: only the number of rows is fixed
SELECT count(*) AS n FROM (SELECT k FROM T LIMIT 0)
