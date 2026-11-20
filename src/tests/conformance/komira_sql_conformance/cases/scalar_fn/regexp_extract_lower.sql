-- order: rows
SELECT k, regexp_extract(s, '[a-z]+') FROM T
