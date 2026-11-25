-- IN (subquery): left rows with a match, each once.
SELECT id, k FROM join_left WHERE k IN (SELECT k FROM join_right) ORDER BY id ASC NULLS LAST
