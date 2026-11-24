-- regexp_matches as a filter and as a value.
SELECT id, s, regexp_matches(s, '^[a-m]') AS first_half FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
