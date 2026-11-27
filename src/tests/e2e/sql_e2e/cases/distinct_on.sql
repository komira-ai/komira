-- DISTINCT ON keeps the first row of each key: the NULL keys are one key,
-- and the lowest id of each wins.
SELECT DISTINCT ON (k) k, id FROM nulls ORDER BY k ASC NULLS FIRST, id ASC NULLS LAST
