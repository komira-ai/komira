-- order: query
SELECT k FROM T WHERE NOT regexp_matches(s, 'z') ORDER BY k
