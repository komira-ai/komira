-- DISTINCT ON a key the SELECT list does not produce: the key is carried for the
-- partition and is not in the result.
SELECT DISTINCT ON (k2) id, lv FROM join_left ORDER BY id ASC NULLS LAST
