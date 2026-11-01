-- tf as a Parquet file.
COPY (SELECT * FROM tf ORDER BY id) TO 'tf.parquet' (FORMAT parquet, ROW_GROUP_SIZE 2048);
