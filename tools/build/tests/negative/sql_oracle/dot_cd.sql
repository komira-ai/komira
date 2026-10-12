-- A dot command that changes the working directory.
.cd ..
COPY (SELECT 1 AS x) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
