-- upper, lower, length and || over words, '' and NULL.
SELECT id, upper(s) AS up, lower(s) AS low, length(s) AS n, s || '!' AS bang FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
