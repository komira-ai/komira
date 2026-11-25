-- INNER JOIN on two key columns.
SELECT l.id AS lid, r.id AS rid FROM join_left AS l JOIN join_right AS r ON l.k = r.k AND l.k2 = r.k2 ORDER BY lid ASC NULLS LAST, rid ASC NULLS LAST
