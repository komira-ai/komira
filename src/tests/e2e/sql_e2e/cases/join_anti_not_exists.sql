-- NOT EXISTS: left rows with no match, NULL keys kept.
SELECT l.id AS id, l.k AS k FROM join_left AS l WHERE NOT EXISTS (SELECT 1 FROM join_right AS r WHERE r.k = l.k) ORDER BY id ASC NULLS LAST
