-- DISTINCT ON keeps the first row of each key.
SELECT DISTINCT ON (k) k, id FROM nulls ORDER BY k ASC NULLS FIRST, id ASC NULLS LAST
