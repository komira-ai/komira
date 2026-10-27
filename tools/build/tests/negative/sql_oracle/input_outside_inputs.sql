-- Reads a file of this package that is not one of its inputs.
COPY (SELECT * FROM read_csv('not_staged.csv')) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
