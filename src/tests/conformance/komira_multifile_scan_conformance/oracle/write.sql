-- The three files of the directory table and the four leaf files of the Hive
-- table, one row group each.
COPY (SELECT * FROM m WHERE id BETWEEN 1 AND 10 ORDER BY id) TO 'dir3_0.parquet' (FORMAT parquet);
COPY (SELECT * FROM m WHERE id BETWEEN 11 AND 20 ORDER BY id) TO 'dir3_1.parquet' (FORMAT parquet);
COPY (SELECT * FROM m WHERE id BETWEEN 21 AND 30 ORDER BY id) TO 'dir3_2.parquet' (FORMAT parquet);
COPY (SELECT id, v, s FROM hl WHERE leaf = 0 ORDER BY id) TO 'hive_0.parquet' (FORMAT parquet);
COPY (SELECT id, v, s FROM hl WHERE leaf = 1 ORDER BY id) TO 'hive_1.parquet' (FORMAT parquet);
COPY (SELECT id, v, s FROM hl WHERE leaf = 2 ORDER BY id) TO 'hive_2.parquet' (FORMAT parquet);
COPY (SELECT id, v, s FROM hl WHERE leaf = 3 ORDER BY id) TO 'hive_3.parquet' (FORMAT parquet);
