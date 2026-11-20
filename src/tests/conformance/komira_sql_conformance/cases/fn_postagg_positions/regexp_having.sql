-- order: rows
-- regexp_extract(s, '[a-z]+') on a group key in having
SELECT s AS z FROM T GROUP BY s HAVING regexp_extract(s, '[a-z]+') = 'abc'
