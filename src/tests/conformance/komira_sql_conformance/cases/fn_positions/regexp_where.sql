-- order: rows
-- regexp_extract(s, '[a-z]+') in the where clause
SELECT k FROM T WHERE regexp_extract(s, '[a-z]+') = 'abc'
