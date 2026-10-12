-- Names its one input by a glob pattern.
COPY (SELECT * FROM read_csv('*.csv')) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
