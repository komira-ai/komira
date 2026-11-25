-- INNER JOIN on a string key: '' matches '', NULL matches nothing.
SELECT l.id AS lid, r.id AS rid, l.k2 AS k2 FROM join_left AS l JOIN join_right AS r ON l.k2 = r.k2 ORDER BY lid ASC NULLS LAST, rid ASC NULLS LAST
