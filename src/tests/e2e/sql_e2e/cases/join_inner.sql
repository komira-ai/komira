-- INNER JOIN on a BIGINT key: duplicates, NULL keys never match.
SELECT l.id AS lid, r.id AS rid, l.k AS k FROM join_left AS l JOIN join_right AS r ON l.k = r.k ORDER BY lid ASC NULLS LAST, rid ASC NULLS LAST
