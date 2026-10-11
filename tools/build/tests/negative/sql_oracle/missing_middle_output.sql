-- Writes two of its three declared outputs: all but middle.tsv.
COPY (SELECT 1 AS x) TO 'first.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
COPY (SELECT 1 AS x) TO 'last.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
