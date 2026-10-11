-- Writes its declared output, then one more file.
COPY (SELECT 1 AS x) TO 'declared.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
COPY (SELECT 2 AS x) TO 'extra.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
