-- Runs after check_bytes.sql: the table `pairs` is still there.
SELECT CASE WHEN count(*) <> 5 THEN error('check_bytes.sql did not run first') END FROM pairs;

-- The Parquet file holds the rows of the CSV input, with its types.
CREATE TABLE want AS
SELECT * FROM read_csv('data.csv', header = true,
    columns = {'id': 'INTEGER', 'name': 'VARCHAR', 'amount': 'DOUBLE', 'ts': 'TIMESTAMPTZ'});

SELECT CASE WHEN count(*) > 0 THEN error('rows.parquet and data.csv differ in ' || count(*) || ' rows') END
FROM ((SELECT * FROM 'a/rows.parquet' EXCEPT ALL SELECT * FROM want)
      UNION ALL (SELECT * FROM want EXCEPT ALL SELECT * FROM 'a/rows.parquet'));

COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM 'a/rows.parquet') ORDER BY column_name)
TO 'schema.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);

-- The column types the Parquet file declares.
SELECT CASE WHEN string_agg(column_name || ' ' || column_type, ', ' ORDER BY column_name)
        <> 'amount DOUBLE, id INTEGER, name VARCHAR, ts TIMESTAMP WITH TIME ZONE'
    THEN error('rows.parquet schema: ' || string_agg(column_name || ' ' || column_type, ', ' ORDER BY column_name)) END
FROM (DESCRIBE SELECT * FROM 'a/rows.parquet');
