-- order: query
SELECT k FROM T WHERE regexp_matches(s, 'z') ORDER BY k
