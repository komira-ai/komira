-- tx as a Parquet file.
COPY (SELECT * FROM tx ORDER BY id) TO 'tx.parquet' (FORMAT parquet, ROW_GROUP_SIZE 2048);
