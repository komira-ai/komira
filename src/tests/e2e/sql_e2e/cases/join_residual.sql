-- An equi-join with a residual predicate over both sides.
SELECT l.id AS lid, r.id AS rid FROM join_left AS l JOIN join_right AS r ON l.k = r.k AND l.id < r.id ORDER BY lid ASC NULLS LAST, rid ASC NULLS LAST
