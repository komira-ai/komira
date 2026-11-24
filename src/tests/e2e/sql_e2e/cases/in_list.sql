-- IN over a list of literals.
SELECT id, k FROM nulls WHERE k IN (1, 3) AND id < 300 ORDER BY id ASC NULLS LAST
