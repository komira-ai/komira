-- The functions of the avro and iceberg extensions exist only once the rule
-- has loaded them (autoload is off): read_avro and iceberg_scan.
SELECT CASE WHEN (SELECT count(DISTINCT function_name) FROM duckdb_functions() WHERE function_name IN ('read_avro', 'iceberg_scan')) <> 2
    THEN error('sql_oracle test: the avro and iceberg extensions did not register read_avro and iceberg_scan') END;

COPY (SELECT DISTINCT function_name FROM duckdb_functions() WHERE function_name IN ('read_avro', 'iceberg_scan') ORDER BY function_name)
TO 'functions.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
