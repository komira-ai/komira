-- order: rows
-- regexp_extract(s, '[a-z]+') in the select list
SELECT k, regexp_extract(s, '[a-z]+') AS z FROM T
