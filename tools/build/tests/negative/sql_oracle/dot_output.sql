-- A dot command that sends results to a file.
.output out.tsv
COPY (SELECT 1 AS x) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
