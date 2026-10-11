-- A dot command that reads a file as SQL.
.read ok.sql
COPY (SELECT 1 AS x) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
