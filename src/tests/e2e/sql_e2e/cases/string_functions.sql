-- upper, lower, length, substr, replace and trim over words, '' and NULL.
SELECT id, upper(s) AS up, lower(s) AS low, length(s) AS n, substr(s, 2, 3) AS sub, replace(s, 'a', 'A') AS rep, trim(s) AS tr FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
