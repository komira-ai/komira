-- FULL JOIN: every row of both sides.
SELECT l.id AS lid, r.id AS rid FROM join_left AS l FULL JOIN join_right AS r ON l.k = r.k ORDER BY lid ASC NULLS LAST, rid ASC NULLS LAST
