-- order: rows
-- regexp_extract(s, '[a-z]+') inside a scalar subquery
SELECT k, (SELECT max(regexp_extract(s, '[a-z]+')) FROM T) AS z FROM T
