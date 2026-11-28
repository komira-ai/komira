-- DISTINCT ON with an ORDER BY that does not begin with the key: the first row
-- of each k under the whole ORDER BY (the highest id), sorted by that ORDER BY.
SELECT DISTINCT ON (k) id, k FROM nulls ORDER BY id DESC NULLS LAST
