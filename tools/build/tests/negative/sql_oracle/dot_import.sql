-- A dot command that loads a file into a table.
.import staged.csv t
COPY (SELECT 1 AS x) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
