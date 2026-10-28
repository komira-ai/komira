-- Each dataset in each format DuckDB writes itself: Parquet (snappy, row
-- groups of 2048 rows, the least this writer makes: it fills a group a
-- vector of 2048 rows at a time, so `nulls` spans three groups and the
-- others one) and CSV (a header; NULL is an empty unquoted field and
-- the empty string is "", the writer's default; a BLOB is its escaped text,
-- `\xFF` for a byte that is not printable ASCII).
COPY (SELECT * FROM types ORDER BY id ASC) TO 'types.parquet' (FORMAT parquet, COMPRESSION snappy, ROW_GROUP_SIZE 2048);
COPY (SELECT * FROM types ORDER BY id ASC) TO 'types.csv' (FORMAT csv, HEADER true);
COPY (SELECT * FROM nulls ORDER BY id ASC) TO 'nulls.parquet' (FORMAT parquet, COMPRESSION snappy, ROW_GROUP_SIZE 2048);
COPY (SELECT * FROM nulls ORDER BY id ASC) TO 'nulls.csv' (FORMAT csv, HEADER true);
COPY (SELECT * FROM join_left ORDER BY id ASC) TO 'join_left.parquet' (FORMAT parquet, COMPRESSION snappy, ROW_GROUP_SIZE 2048);
COPY (SELECT * FROM join_left ORDER BY id ASC) TO 'join_left.csv' (FORMAT csv, HEADER true);
COPY (SELECT * FROM join_right ORDER BY id ASC) TO 'join_right.parquet' (FORMAT parquet, COMPRESSION snappy, ROW_GROUP_SIZE 2048);
COPY (SELECT * FROM join_right ORDER BY id ASC) TO 'join_right.csv' (FORMAT csv, HEADER true);
