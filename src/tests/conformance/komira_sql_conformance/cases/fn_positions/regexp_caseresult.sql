-- order: rows
-- regexp_extract(s, '[a-z]+') in a case result
SELECT k, CASE WHEN k < 3 THEN regexp_extract(s, '[a-z]+') ELSE 'X' END AS z FROM T
