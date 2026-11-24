-- A boolean column as the whole predicate: NULL rows dropped.
SELECT id FROM nulls WHERE b1 AND id < 500 ORDER BY id ASC NULLS LAST
