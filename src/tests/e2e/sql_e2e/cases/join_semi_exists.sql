-- EXISTS with a correlated equality.
SELECT l.id AS id FROM join_left AS l WHERE EXISTS (SELECT 1 FROM join_right AS r WHERE r.k2 = l.k2) ORDER BY id ASC NULLS LAST
