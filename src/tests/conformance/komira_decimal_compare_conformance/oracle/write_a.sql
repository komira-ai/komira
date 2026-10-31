-- pa as a Parquet file.
COPY (SELECT * FROM pa ORDER BY k, v) TO 'pa.parquet' (FORMAT parquet, ROW_GROUP_SIZE 2048);
