-- An uncorrelated scalar subquery.
SELECT id, i32, (SELECT max(i32) FROM nulls) AS mx FROM nulls WHERE id < 10 ORDER BY id ASC NULLS LAST
