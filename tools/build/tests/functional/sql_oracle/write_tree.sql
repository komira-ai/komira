-- A partitioned COPY into an output directory (`output_dirs`), and the list
-- of the files it made, read back with glob() under that directory.
CREATE TABLE t AS
SELECT * FROM read_csv('data.csv', header = true,
    columns = {'id': 'INTEGER', 'name': 'VARCHAR', 'amount': 'DOUBLE', 'ts': 'TIMESTAMPTZ'});

COPY (SELECT id, name, amount IS NULL AS no_amount FROM t ORDER BY id)
TO 'tree' (FORMAT csv, PARTITION_BY (no_amount));

COPY (SELECT file FROM glob('tree/**') ORDER BY file) TO 'files.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
