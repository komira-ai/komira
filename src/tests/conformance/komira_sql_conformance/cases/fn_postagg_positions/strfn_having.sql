-- order: rows
-- upper(s) on a group key in having
SELECT s AS z FROM T GROUP BY s HAVING upper(s) = 'ABC'
