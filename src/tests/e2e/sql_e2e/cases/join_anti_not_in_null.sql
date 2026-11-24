-- NOT IN over a subquery holding a NULL: no row, the header alone.
SELECT id FROM join_left WHERE k NOT IN (SELECT k FROM join_right) ORDER BY id ASC NULLS LAST
