-- order: rows
-- regexp_extract(max(s), '[a-z]+') around an aggregate in the select list
SELECT regexp_extract(max(s), '[a-z]+') AS z FROM T
