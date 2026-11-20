-- order: rows
-- strpos(s, 'b') on a group key in having
SELECT s AS z FROM T GROUP BY s HAVING strpos(s, 'b') > 0
