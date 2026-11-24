-- INTERSECT: distinct keys of both sides, NULL equal to NULL.
SELECT k FROM join_left INTERSECT SELECT k FROM join_right ORDER BY k ASC NULLS FIRST
