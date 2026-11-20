-- order: rows
SELECT k, regexp_full_match(s, '[a-z]+') FROM T
