-- order: rows
-- regexp_extract(s, '[a-z]+') as an aggregate argument
SELECT max(regexp_extract(s, '[a-z]+')) AS z FROM T
