-- order: rows
SELECT k, regexp_matches(s, '[a-z]+') FROM T
