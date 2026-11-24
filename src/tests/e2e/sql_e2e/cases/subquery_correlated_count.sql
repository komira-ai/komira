-- A correlated scalar subquery with an aggregate body.
SELECT l.id AS id, l.k AS k, (SELECT count(*) FROM join_right AS r WHERE r.k = l.k) AS n FROM join_left AS l ORDER BY id ASC NULLS LAST
