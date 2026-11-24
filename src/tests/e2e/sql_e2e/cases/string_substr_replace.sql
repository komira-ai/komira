-- substr, replace and trim.
SELECT id, substr(s, 2, 3) AS sub, replace(s, 'a', 'A') AS rep, trim(' ' || s || ' ') AS tr FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
