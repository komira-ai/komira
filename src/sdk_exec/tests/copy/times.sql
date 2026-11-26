-- The Parquet file `times.parquet` that the timestamp and integer cases of
-- cases.sql read, written by the pinned DuckDB (the `:copy_times_input` build
-- action), so komira and DuckDB copy the same rows. One row per id:
--   ts   TIMESTAMP     NULL, the epoch, a microsecond before it, fractions of
--                      a second (.123456, .5, .12, .000001), 1900, year 1,
--                      the day before year 1 (1 BC), DuckDB's smallest
--                      (290309 BC) and largest (294247) values, infinity and
--                      -infinity, year 10000 and 1969
--   ms   TIMESTAMP_MS  ts at millisecond precision (the cast rounds), except
--                      for 294247, which holds the largest millisecond value
--                      the pinned DuckDB reads back (.775; ts rounds to .776,
--                      which it writes but cannot read)
--   ns   TIMESTAMP_NS  NULL, the epoch, a nanosecond before it, fractions
--                      down to one nanosecond, the smallest and largest whole
--                      days the type holds (1677 and 2262), infinity and
--                      -infinity; NULL where ts is outside its range
--   tz   TIMESTAMPTZ   ts as an instant (the session time zone is UTC); NULL
--                      for 290309 BC, 294247 and year 10000, which DuckDB's
--                      time zone library cannot convert
--   i8 .. u64          TINYINT, SMALLINT, UTINYINT, USMALLINT, UINTEGER and
--                      UBIGINT: NULL, 0, -1 or 1, each type's minimum and
--                      maximum, and 2^31 and 2^63 for the two widest
--                      unsigned types
CREATE TABLE t (id INTEGER, ts TIMESTAMP, ns TIMESTAMP_NS, i8 TINYINT, i16 SMALLINT, u8 UTINYINT, u16 USMALLINT, u32 UINTEGER, u64 UBIGINT);
INSERT INTO t VALUES (1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO t VALUES (2, make_timestamp(0::BIGINT), make_timestamp_ns(0::BIGINT), 0, 0, 0, 0, 0, 0);
INSERT INTO t VALUES (3, make_timestamp(-1::BIGINT), make_timestamp_ns(-1::BIGINT), -1, -1, 1, 1, 1, 1);
INSERT INTO t VALUES (4, TIMESTAMP '2015-09-04 12:30:45.123456', make_timestamp_ns(1441369845123456789::BIGINT), -128, -32768, 255, 65535, 4294967295, 18446744073709551615);
INSERT INTO t VALUES (5, TIMESTAMP '2015-09-04 12:30:45.5', make_timestamp_ns(1441369845120000000::BIGINT), 127, 32767, 0, 0, 2147483648, 9223372036854775808);
INSERT INTO t VALUES (6, TIMESTAMP '2015-09-04 12:30:45.12', make_timestamp_ns(1441369845000000001::BIGINT), 1, 2, 3, 4, 5, 6);
INSERT INTO t VALUES (7, TIMESTAMP '2015-09-04 12:30:45.000001', make_timestamp_ns(1441369845123456000::BIGINT), NULL, 7, NULL, 7, NULL, 7);
INSERT INTO t VALUES (8, TIMESTAMP '1900-01-01 01:02:03.4', make_timestamp_ns(-2208985076600000000::BIGINT), 7, NULL, 7, NULL, 7, NULL);
INSERT INTO t VALUES (9, TIMESTAMP '0001-01-01 00:00:00', make_timestamp_ns(-9223286400000000000::BIGINT), -7, -7, 9, 9, 9, 9);
INSERT INTO t VALUES (10, TIMESTAMP '0001-12-31 (BC) 00:00:00', make_timestamp_ns(9223286400000000000::BIGINT), 100, 1000, 200, 2000, 3000000000, 12000000000000000000);
INSERT INTO t VALUES (11, TIMESTAMP '290309-12-22 (BC) 00:00:00', NULL, 0, 0, 0, 0, 0, 0);
INSERT INTO t VALUES (12, TIMESTAMP '294247-01-10 04:00:54.775806', NULL, 0, 0, 0, 0, 0, 0);
INSERT INTO t VALUES (13, TIMESTAMP 'infinity', TIMESTAMP_NS 'infinity', 0, 0, 0, 0, 0, 0);
INSERT INTO t VALUES (14, TIMESTAMP '-infinity', TIMESTAMP_NS '-infinity', 0, 0, 0, 0, 0, 0);
INSERT INTO t VALUES (15, TIMESTAMP '10000-01-01 00:00:00', NULL, 0, 0, 0, 0, 0, 0);
INSERT INTO t VALUES (16, TIMESTAMP '1969-07-20 20:17:40', make_timestamp_ns(-14182940000000000::BIGINT), 0, 0, 0, 0, 0, 0);
COPY (SELECT id, ts, CASE WHEN id = 12 THEN TIMESTAMP '294247-01-10 04:00:54.775' ELSE ts END::TIMESTAMP_MS AS ms, ns, CASE WHEN id IN (11, 12, 15) THEN NULL ELSE ts::TIMESTAMPTZ END AS tz, i8, i16, u8, u16, u32, u64 FROM t ORDER BY id) TO 'times.parquet';
