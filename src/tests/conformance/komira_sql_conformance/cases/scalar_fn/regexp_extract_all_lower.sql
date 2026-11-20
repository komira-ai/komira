-- order: rows
SELECT k, regexp_extract_all(s, '[a-z]+') FROM T
