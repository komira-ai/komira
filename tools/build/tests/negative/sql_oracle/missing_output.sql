-- Writes one of its two declared outputs.
COPY (SELECT 1 AS x) TO 'written.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
