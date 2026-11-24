-- CROSS JOIN of two filtered sides.
SELECT l.id AS lid, r.id AS rid FROM join_left AS l CROSS JOIN join_right AS r WHERE l.id < 3 AND r.id < 4 ORDER BY lid ASC NULLS LAST, rid ASC NULLS LAST
