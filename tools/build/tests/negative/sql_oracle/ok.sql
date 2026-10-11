-- Writes its output well: the targets refused at analysis never run it.
COPY (SELECT 1 AS x) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
