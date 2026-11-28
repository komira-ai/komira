-- The tables of test_run_plan_asof, written by DuckDB as Parquet and as CSV
-- with the same rows, so each case runs over both leaf kinds.
--
-- q, the quotes (9 rows, not in ts order):
--   sym VARCHAR    the group; one row has a NULL sym
--   ts  BIGINT     the as-of key; one row has a NULL ts, and B holds two
--                  rows at ts 15
--   tts TIMESTAMP  the same instant as ts, ts minutes after 2028-03-01 09:00
--   px  BIGINT     the price
--   qid BIGINT     the row's id
-- t, the trades (10 rows, not in ts order):
--   id  BIGINT     the row's id
--   sym VARCHAR    the group: A, B and C have quotes, D has none, one is NULL
--   ts  BIGINT     the as-of key; one row has a NULL ts
--   tts TIMESTAMP  as q.tts
--   qty BIGINT
-- q2, the rows of q in another order: B's two quotes at ts 15 swapped.
-- e, the quotes with no row; te, the trades with no row.
--
-- The Parquet files are in row groups of 3 rows, so a scan reads several
-- morsels.
CREATE TABLE q AS
SELECT sym, ts, TIMESTAMP '2028-03-01 09:00:00' + to_minutes(ts) AS tts, px, qid
FROM (VALUES
    ('A', 30, 300, 3),
    ('B', 15, 150, 4),
    ('A', 10, 100, 1),
    (NULL, 5, 50, 7),
    ('B', 40, 400, 6),
    ('A', 20, 200, 2),
    ('A', NULL, 999, 8),
    ('B', 15, 151, 5),
    ('C', 100, 1000, 9)
) v(sym, ts, px, qid);

CREATE TABLE t AS
SELECT id, sym, ts, TIMESTAMP '2028-03-01 09:00:00' + to_minutes(ts) AS tts, qty
FROM (VALUES
    (5, 'B', 50, 50),
    (1, 'A', 25, 10),
    (7, NULL, 20, 70),
    (3, 'A', 5, 30),
    (10, 'C', 99, 100),
    (2, 'A', 10, 20),
    (8, 'A', NULL, 80),
    (4, 'B', 15, 40),
    (9, 'A', 35, 90),
    (6, 'D', 20, 60)
) v(id, sym, ts, qty);

CREATE TABLE q2 AS
SELECT * FROM q WHERE qid <> 4
UNION ALL SELECT * FROM q WHERE qid = 4;

CREATE TABLE e AS SELECT * FROM q WHERE false;
CREATE TABLE te AS SELECT * FROM t WHERE false;

COPY q TO 'q.parquet' (FORMAT parquet, ROW_GROUP_SIZE 3);
COPY q2 TO 'q2.parquet' (FORMAT parquet, ROW_GROUP_SIZE 3);
COPY t TO 't.parquet' (FORMAT parquet, ROW_GROUP_SIZE 3);
COPY e TO 'e.parquet' (FORMAT parquet);
COPY te TO 'te.parquet' (FORMAT parquet);
COPY q TO 'q.csv' (FORMAT csv, HEADER true);
COPY q2 TO 'q2.csv' (FORMAT csv, HEADER true);
COPY t TO 't.csv' (FORMAT csv, HEADER true);
