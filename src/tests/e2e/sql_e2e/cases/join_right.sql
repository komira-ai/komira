-- RIGHT JOIN: every right row.
SELECT l.id AS lid, r.id AS rid, r.k AS k FROM join_left AS l RIGHT JOIN join_right AS r ON l.k = r.k ORDER BY rid ASC NULLS LAST, lid ASC NULLS LAST
