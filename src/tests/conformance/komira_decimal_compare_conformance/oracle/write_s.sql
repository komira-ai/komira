-- pj, pd and pg as Parquet files.
COPY (SELECT * FROM pj ORDER BY k, v) TO 'pj.parquet' (FORMAT parquet, ROW_GROUP_SIZE 2048);
COPY (SELECT * FROM pd ORDER BY k, d0) TO 'pd.parquet' (FORMAT parquet, ROW_GROUP_SIZE 2048);
COPY (SELECT * FROM pg ORDER BY k) TO 'pg.parquet' (FORMAT parquet, ROW_GROUP_SIZE 2048);
