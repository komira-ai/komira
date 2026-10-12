-- A dot command that runs a program.
.system true
COPY (SELECT 1 AS x) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
