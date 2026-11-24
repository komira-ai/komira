-- LEFT JOIN: every left row, NULLs where no right row matches.
SELECT l.id AS lid, r.id AS rid, l.k AS k, r.rv AS rv FROM join_left AS l LEFT JOIN join_right AS r ON l.k = r.k ORDER BY lid ASC NULLS LAST, rid ASC NULLS LAST
