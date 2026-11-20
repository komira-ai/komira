-- order: rows
-- s on a group key in having
SELECT s AS z FROM T GROUP BY s HAVING s = 'abc'
