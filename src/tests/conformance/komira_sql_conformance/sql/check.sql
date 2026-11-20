-- answer.tsv (answer.sql) must equal expected.tsv, the committed answer,
-- byte for byte; else the action fails with where they first differ
-- (first_difference, compare.sql).
CREATE TABLE texts AS SELECT
    (SELECT content FROM read_text('answer.tsv')) AS got,
    (SELECT content FROM read_text('expected.tsv')) AS want;
SELECT error('corpus case: answer.tsv differs from the committed expected.tsv, ' || d)
FROM (SELECT first_difference(got, want) AS d FROM texts)
WHERE d IS NOT NULL;
