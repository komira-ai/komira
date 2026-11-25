-- CASE WHEN with no ELSE answers NULL.
SELECT id, CASE WHEN k = 1 THEN 'one' WHEN k = 2 THEN 'two' END AS name FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
