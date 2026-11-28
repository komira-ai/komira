-- DISTINCT ON two keys keeps the first row of each (k, b1) pair, NULLs grouped.
SELECT DISTINCT ON (k, b1) k, b1, id FROM nulls ORDER BY k ASC NULLS LAST, b1 ASC NULLS LAST, id ASC NULLS LAST
