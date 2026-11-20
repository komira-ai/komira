-- order: rows
-- regexp_extract(s, '[a-z]+') in a case condition
SELECT k, CASE WHEN regexp_extract(s, '[a-z]+') = 'abc' THEN 'y' ELSE 'n' END AS z FROM T
