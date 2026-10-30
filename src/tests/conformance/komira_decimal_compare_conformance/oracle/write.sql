-- t as a Parquet file: the table the test registers. Row groups of 2048 rows
-- (the writer's least).
COPY (SELECT * FROM t ORDER BY id) TO 't.parquet' (FORMAT parquet, ROW_GROUP_SIZE 2048);
