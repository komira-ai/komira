-- Reads a file by absolute path.
COPY (SELECT * FROM read_csv('/etc/passwd')) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
