-- The tables of test_run_sql_set_ops, written by DuckDB as Parquet files.
--
-- ta, tb, tn, te (k BIGINT, g VARCHAR): the arms of the conformance corpus's
-- set_operations cases. ta and tb share the row (3, 'x') and the all-NULL row,
-- tb also holds (NULL, 'w'); tn is three all-NULL rows; te has no row; ab is
-- ta's rows then tb's; tv (k VARCHAR, g VARCHAR) holds the string '3', which
-- equals ta's 3 once ta's BIGINT key is widened to VARCHAR, and 'abc'.
--
-- z0 and zn (f DOUBLE): z0 holds 0.0 and zn -0.0 (each twice), with NaN twice,
-- NULL and one value of its own, so a UNION of the two meets a NaN, a NULL and
-- a zero in either input.
--
-- l.parquet (2000 rows, row groups of 512) and r.parquet (1500 rows): each
-- column a function of the row number n, with NULLs at a period of its own, so
-- rows repeat within a file and the two files share some rows and not others.
--
-- i    INTEGER        l: n % 7 - 3            r: n % 5 - 1
-- big  BIGINT         l: (n % 4) * 3000000000 r: (n % 6) * 3000000000
-- s    VARCHAR        'key_0' .. 'key_3', the empty string where n % 11 = 1
-- d    DATE           1969-12-20 plus 0 to 5 (l) or 0 to 3 (r) times 45 days
-- m    DECIMAL(12,2)  l: (n % 9 - 4) * 1.25   r: (n % 6 - 2) * 1.25
-- f    DOUBLE         n % 5 (l) or n % 8 (r) halved, NaN where n % 10 = 1
CREATE TABLE ta (k BIGINT, g VARCHAR);
INSERT INTO ta VALUES (1, 'x'), (2, 'y'), (3, 'x'), (NULL, NULL);
CREATE TABLE tb (k BIGINT, g VARCHAR);
INSERT INTO tb VALUES (3, 'x'), (4, 'z'), (NULL, NULL), (NULL, 'w');
CREATE TABLE tn (k BIGINT, g VARCHAR);
INSERT INTO tn VALUES (NULL, NULL), (NULL, NULL), (NULL, NULL);
CREATE TABLE te (k BIGINT, g VARCHAR);
CREATE TABLE tv (k VARCHAR, g VARCHAR);
INSERT INTO tv VALUES ('3', 'x'), ('abc', 'q');
CREATE TABLE z0 (f DOUBLE);
INSERT INTO z0 VALUES (CAST('0' AS DOUBLE)), (CAST('NaN' AS DOUBLE)), (NULL), (1.5), (CAST('NaN' AS DOUBLE)), (CAST('0' AS DOUBLE));
CREATE TABLE zn (f DOUBLE);
INSERT INTO zn VALUES (CAST('-0' AS DOUBLE)), (CAST('NaN' AS DOUBLE)), (NULL), (2.5), (CAST('-0' AS DOUBLE));
COPY ta TO 'ta.parquet' (FORMAT parquet);
COPY tb TO 'tb.parquet' (FORMAT parquet);
COPY tn TO 'tn.parquet' (FORMAT parquet);
COPY te TO 'te.parquet' (FORMAT parquet);
COPY tv TO 'tv.parquet' (FORMAT parquet);
COPY z0 TO 'z0.parquet' (FORMAT parquet);
COPY zn TO 'zn.parquet' (FORMAT parquet);
COPY (SELECT k, g FROM ta UNION ALL SELECT k, g FROM tb) TO 'ab.parquet' (FORMAT parquet);
COPY (
    SELECT
        CASE WHEN n % 13 = 0 THEN NULL ELSE CAST(n % 7 - 3 AS INTEGER) END AS i,
        CASE WHEN n % 17 = 0 THEN NULL ELSE CAST(n % 4 AS BIGINT) * 3000000000 END AS big,
        CASE WHEN n % 11 = 0 THEN NULL WHEN n % 11 = 1 THEN '' ELSE 'key_' || CAST(n % 4 AS VARCHAR) END AS s,
        CASE WHEN n % 19 = 0 THEN NULL ELSE DATE '1969-12-20' + CAST(n % 6 AS INTEGER) * 45 END AS d,
        CASE WHEN n % 23 = 0 THEN NULL ELSE CAST((n % 9 - 4) * 1.25 AS DECIMAL(12, 2)) END AS m,
        CASE WHEN n % 29 = 0 THEN NULL WHEN n % 10 = 1 THEN CAST('NaN' AS DOUBLE) ELSE CAST(n % 5 AS DOUBLE) / 2 END AS f
    FROM range(2000) t(n)
) TO 'l.parquet' (FORMAT parquet, ROW_GROUP_SIZE 512);
COPY (
    SELECT
        CASE WHEN n % 7 = 0 THEN NULL ELSE CAST(n % 5 - 1 AS INTEGER) END AS i,
        CASE WHEN n % 13 = 0 THEN NULL ELSE CAST(n % 6 AS BIGINT) * 3000000000 END AS big,
        CASE WHEN n % 11 = 0 THEN NULL WHEN n % 11 = 1 THEN '' ELSE 'key_' || CAST(n % 4 AS VARCHAR) END AS s,
        CASE WHEN n % 17 = 0 THEN NULL ELSE DATE '1969-12-20' + CAST(n % 4 AS INTEGER) * 45 END AS d,
        CASE WHEN n % 19 = 0 THEN NULL ELSE CAST((n % 6 - 2) * 1.25 AS DECIMAL(12, 2)) END AS m,
        CASE WHEN n % 23 = 0 THEN NULL WHEN n % 10 = 1 THEN CAST('NaN' AS DOUBLE) ELSE CAST(n % 8 AS DOUBLE) / 2 END AS f
    FROM range(1500) t(n)
) TO 'r.parquet' (FORMAT parquet, ROW_GROUP_SIZE 512);
