-- A dot command that reaches the system.
.shell true
COPY (SELECT 1 AS x) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
