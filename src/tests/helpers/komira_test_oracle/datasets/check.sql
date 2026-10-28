-- datasets_check: runs after gen.sql and the dataset files, which rebuild
-- the tables in this session, and holds the files `datasets` wrote (staged
-- under a/) to them; `datasets_twin`'s (under b/) are the same SQL run as
-- another action.

-- 1. Determinism: every file byte for byte its twin's.
CREATE TABLE files AS
SELECT d || '.' || f AS name FROM (VALUES ('types'), ('nulls'), ('join_left'), ('join_right')) AS a(d),
    (VALUES ('parquet'), ('csv')) AS b(f);
CREATE TABLE blobs AS SELECT filename, content FROM read_blob([
    'a/types.parquet', 'a/types.csv', 'a/nulls.parquet', 'a/nulls.csv',
    'a/join_left.parquet', 'a/join_left.csv', 'a/join_right.parquet', 'a/join_right.csv',
    'b/types.parquet', 'b/types.csv', 'b/nulls.parquet', 'b/nulls.csv',
    'b/join_left.parquet', 'b/join_left.csv', 'b/join_right.parquet', 'b/join_right.csv']);
SELECT CASE WHEN count(*) <> 8 THEN error('datasets: ' || count(*) || ' of 8 files have a twin to compare with') END
FROM files JOIN blobs x ON x.filename = 'a/' || files.name JOIN blobs y ON y.filename = 'b/' || files.name;
SELECT CASE WHEN count(*) > 0 THEN error('datasets: not byte for byte the twin''s: ' || string_agg(files.name, ', ' ORDER BY files.name)) END
FROM files JOIN blobs x ON x.filename = 'a/' || files.name JOIN blobs y ON y.filename = 'b/' || files.name
WHERE x.content <> y.content;

-- 2. Each file holds its table's rows (EXCEPT ALL both ways: a lost,
-- added or changed row, and a duplicate). signbit() rides along with each
-- float column, because -0.0 = 0.0 in SQL; NaN equals NaN in DuckDB's
-- set operations.
CREATE MACRO types_rows(t) AS TABLE
    SELECT *, signbit(f32) AS f32_sign, signbit(f64) AS f64_sign,
        signbit(f32_special) AS f32_special_sign, signbit(f64_special) AS f64_special_sign
    FROM query_table(t);
CREATE MACRO diff(want, got) AS TABLE
    (FROM query_table(want) EXCEPT ALL FROM query_table(got))
    UNION ALL (FROM query_table(got) EXCEPT ALL FROM query_table(want));

CREATE VIEW types_parquet AS FROM read_parquet('a/types.parquet');
CREATE VIEW nulls_parquet AS FROM read_parquet('a/nulls.parquet');
CREATE VIEW join_left_parquet AS FROM read_parquet('a/join_left.parquet');
CREATE VIEW join_right_parquet AS FROM read_parquet('a/join_right.parquet');

-- A CSV is read with the table's own column types. allow_quoted_nulls =
-- false: the writer spells the empty string "" and NULL as nothing, and the
-- reader's default would read both as NULL.
CREATE MACRO csv(f, cols) AS TABLE
    FROM read_csv(f, header = true, auto_detect = false, delim = ',', quote = '"', escape = '"',
                  nullstr = '', allow_quoted_nulls = false, columns = cols);
CREATE VIEW types_csv AS FROM csv('a/types.csv', {
    'id': 'BIGINT', 'i8': 'TINYINT', 'i16': 'SMALLINT', 'i32': 'INTEGER', 'i64': 'BIGINT',
    'u8': 'UTINYINT', 'u16': 'USMALLINT', 'u32': 'UINTEGER', 'u64': 'UBIGINT',
    'f32': 'FLOAT', 'f64': 'DOUBLE', 'f32_special': 'FLOAT', 'f64_special': 'DOUBLE',
    'dec_9_2': 'DECIMAL(9,2)', 'dec_38_10': 'DECIMAL(38,10)', 'str': 'VARCHAR', 'bin': 'BLOB', 'bin_raw': 'BLOB',
    'date32': 'DATE', 'ts_s': 'TIMESTAMP_S', 'ts_ms': 'TIMESTAMP_MS', 'ts_us': 'TIMESTAMP', 'ts_ns': 'TIMESTAMP_NS',
    'ts_tz': 'TIMESTAMPTZ', 'bool': 'BOOLEAN'});
CREATE VIEW nulls_csv AS FROM csv('a/nulls.csv', {
    'id': 'BIGINT', 'k': 'BIGINT', 'b1': 'BOOLEAN', 'b2': 'BOOLEAN', 'i32': 'INTEGER', 'v': 'DOUBLE',
    's': 'VARCHAR', 'all_null': 'BIGINT'});
CREATE VIEW join_left_csv AS FROM csv('a/join_left.csv', {'id': 'BIGINT', 'k': 'BIGINT', 'k2': 'VARCHAR', 'lv': 'INTEGER'});
CREATE VIEW join_right_csv AS FROM csv('a/join_right.csv', {'id': 'BIGINT', 'k': 'BIGINT', 'k2': 'VARCHAR', 'rv': 'VARCHAR'});

CREATE VIEW types_want AS FROM types_rows('types');
CREATE VIEW types_parquet_rows AS FROM types_rows('types_parquet');
CREATE VIEW types_csv_rows AS FROM types_rows('types_csv');

CREATE TABLE row_diffs AS
          SELECT 'types.parquet' AS file, count(*) AS n FROM diff('types_want', 'types_parquet_rows')
UNION ALL SELECT 'types.csv', count(*) FROM diff('types_want', 'types_csv_rows')
UNION ALL SELECT 'nulls.parquet', count(*) FROM diff('nulls', 'nulls_parquet')
UNION ALL SELECT 'nulls.csv', count(*) FROM diff('nulls', 'nulls_csv')
UNION ALL SELECT 'join_left.parquet', count(*) FROM diff('join_left', 'join_left_parquet')
UNION ALL SELECT 'join_left.csv', count(*) FROM diff('join_left', 'join_left_csv')
UNION ALL SELECT 'join_right.parquet', count(*) FROM diff('join_right', 'join_right_parquet')
UNION ALL SELECT 'join_right.csv', count(*) FROM diff('join_right', 'join_right_csv');
SELECT CASE WHEN count(*) > 0 THEN error('datasets: rows differ from the table: ' || string_agg(file || ' (' || n || ')', ', ' ORDER BY file)) END
FROM row_diffs WHERE n > 0;

-- 3. Parquet layout: snappy, row groups of 2048 rows (the last one shorter).
SELECT CASE WHEN count(*) > 0 THEN error('datasets: parquet layout: ' || string_agg(DISTINCT file_name || ' group ' || row_group_id || ' (' || row_group_num_rows || ' rows, ' || compression || ')', ', ')) END
FROM parquet_metadata(['a/types.parquet', 'a/nulls.parquet', 'a/join_left.parquet', 'a/join_right.parquet']) m
WHERE compression <> 'SNAPPY'
   OR row_group_num_rows <> least(2048, CASE file_name
        WHEN 'a/types.parquet' THEN (SELECT count(*) FROM types) WHEN 'a/nulls.parquet' THEN (SELECT count(*) FROM nulls)
        WHEN 'a/join_left.parquet' THEN (SELECT count(*) FROM join_left) ELSE (SELECT count(*) FROM join_right) END - 2048 * row_group_id);

-- 4. The values the shards rely on, held in the tables themselves (so a
-- generator change that drops one fails here by name).
CREATE TABLE wants (what VARCHAR, ok BOOLEAN);
INSERT INTO wants
SELECT 'types: ' || count(*) || ' rows, not 256', count(*) = 256 FROM types
UNION ALL SELECT 'types: every column but id holds a NULL and a value',
    (SELECT bool_and(c > 0 AND c < 256) FROM (UNPIVOT (SELECT count(COLUMNS(* EXCLUDE (id))) FROM types) ON COLUMNS(*) INTO NAME col VALUE c))
UNION ALL SELECT 'types: the integer extremes', (SELECT min(i8) = -128 AND max(i8) = 127 AND min(i16) = -32768 AND max(i16) = 32767
    AND min(i32) = -2147483648 AND max(i32) = 2147483647 AND min(i64) = -9223372036854775808 AND max(i64) = 9223372036854775807
    AND min(u8) = 0 AND max(u8) = 255 AND max(u16) = 65535 AND max(u32) = 4294967295 AND max(u64) = 18446744073709551615 FROM types)
UNION ALL SELECT 'types: -0.0 and 0.0 in f32 and f64',
    (SELECT count(*) FILTER (f32 = 0 AND signbit(f32)) > 0 AND count(*) FILTER (f32 = 0 AND NOT signbit(f32)) > 0
        AND count(*) FILTER (f64 = 0 AND signbit(f64)) > 0 AND count(*) FILTER (f64 = 0 AND NOT signbit(f64)) > 0 FROM types)
UNION ALL SELECT 'types: the least subnormals and the extremes',
    (SELECT count(*) FILTER (f32 = CAST('1.4e-45' AS FLOAT)) = 1 AND count(*) FILTER (f64 = CAST('5e-324' AS DOUBLE)) = 1
        AND count(*) FILTER (f64 = CAST('-5e-324' AS DOUBLE)) = 1
        AND max(f32) = CAST('3.4028235e38' AS FLOAT) AND min(f32) = CAST('-3.4028235e38' AS FLOAT)
        AND max(f64) = CAST('1.7976931348623157e308' AS DOUBLE) AND min(f64) = CAST('-1.7976931348623157e308' AS DOUBLE) FROM types)
UNION ALL SELECT 'types: f32 and f64 finite, NaN and both infinities in the _special columns only',
    (SELECT count(*) FILTER (isnan(f32) OR isinf(f32) OR isnan(f64) OR isinf(f64)) = 0
        AND count(*) FILTER (isnan(f32_special)) > 0 AND count(*) FILTER (f32_special = CAST('inf' AS FLOAT)) > 0
        AND count(*) FILTER (f32_special = CAST('-inf' AS FLOAT)) > 0
        AND count(*) FILTER (isnan(f64_special)) > 0 AND count(*) FILTER (f64_special = CAST('inf' AS DOUBLE)) > 0
        AND count(*) FILTER (f64_special = CAST('-inf' AS DOUBLE)) > 0 FROM types)
UNION ALL SELECT 'types: the decimal extremes and least steps',
    (SELECT max(dec_9_2) = CAST('9999999.99' AS DECIMAL(9,2)) AND min(dec_9_2) = CAST('-9999999.99' AS DECIMAL(9,2))
        AND count(*) FILTER (dec_9_2 = CAST('-0.01' AS DECIMAL(9,2))) > 0
        AND max(dec_38_10) = CAST('9999999999999999999999999999.9999999999' AS DECIMAL(38,10))
        AND count(*) FILTER (dec_38_10 = CAST('0.0000000001' AS DECIMAL(38,10))) > 0 FROM types)
UNION ALL SELECT 'types: the special strings', (SELECT count(DISTINCT str) FILTER (str IN ('', '\N', 'NULL', 'NaN', 'say "hi"',
    'line' || chr(10) || 'break', 'tab' || chr(9) || 'here', 'cr' || chr(13) || 'here', 'back\slash', '😀')) = 10 FROM types)
UNION ALL SELECT 'types: bin_raw holds bytes that are not UTF-8', (SELECT count(*) FILTER (bin_raw = CAST('\xFF' AS BLOB)) = 1 FROM types)
UNION ALL SELECT 'types: the first and last date and instant of each column',
    (SELECT min(date32) = DATE '0001-01-01' AND max(date32) = DATE '9999-12-31'
        AND min(ts_s) = CAST('0001-01-01' AS TIMESTAMP_S) AND max(ts_s) = CAST('9999-12-31 23:59:59' AS TIMESTAMP_S)
        AND max(ts_ms) = CAST('9999-12-31 23:59:59.999' AS TIMESTAMP_MS) AND max(ts_us) = TIMESTAMP '9999-12-31 23:59:59.999999'
        AND min(ts_ns) = make_timestamp_ns(-9223286400000000000) AND max(ts_ns) = make_timestamp_ns(9223372036854775806)
        AND max(ts_tz) = CAST('9999-12-31 23:59:59.999999+00' AS TIMESTAMPTZ) FROM types)
UNION ALL SELECT 'nulls: the first nine rows are every pair of TRUE, FALSE, NULL',
    (SELECT count(DISTINCT coalesce(CAST(b1 AS VARCHAR), 'n') || coalesce(CAST(b2 AS VARCHAR), 'n')) = 9 FROM nulls WHERE id < 9)
UNION ALL SELECT 'nulls: 5000 rows; k, i32, v and s with NULLs, s with '''', all_null all NULL',
    (SELECT count(*) = 5000 AND count(k) < 5000 AND count(i32) < 5000 AND count(v) < 5000 AND count(s) < 5000
        AND count(*) FILTER (s = '') > 0 AND count(all_null) = 0 AND bool_and(v * 4 = round(v * 4)) FROM nulls)
UNION ALL SELECT 'joins: NULL keys, 1 twice, 9 only left, 10 only right',
    (SELECT count(*) FILTER (k IS NULL) > 0 AND count(*) FILTER (k = 1) >= 2 AND count(*) FILTER (k = 9) > 0
        AND count(*) FILTER (k = 10) = 0 FROM join_left)
    AND (SELECT count(*) FILTER (k IS NULL) > 0 AND count(*) FILTER (k = 1) >= 2 AND count(*) FILTER (k = 10) > 0
        AND count(*) FILTER (k = 9) = 0 FROM join_right)
    AND (SELECT count(*) FILTER (k2 = '') > 0 AND count(*) FILTER (k2 IS NULL) > 0 FROM join_left);
SELECT CASE WHEN count(*) > 0 THEN error('datasets: ' || string_agg(what, '; ' ORDER BY what)) END FROM wants WHERE ok IS NOT true;

-- 5. The summary, held to the committed golden byte for byte: per dataset
-- and column, the type the Parquet file declares, the rows, the values
-- that are not NULL, min and max (`(none)` for a column of only NULLs), and an md5 of every value in id order (NULL spelt apart from
-- every value), so any change to what the generator builds shows in review.
CREATE TABLE summary (dataset VARCHAR, column_name VARCHAR, column_type VARCHAR, rows BIGINT, non_null BIGINT, min VARCHAR, max VARCHAR, content_md5 VARCHAR);
INSERT INTO summary
SELECT 'types', t.column_name, t.column_type, (SELECT count(*) FROM types_parquet), n.v, lo.v, hi.v, h.v
FROM (DESCRIBE FROM types_parquet) t
JOIN (UNPIVOT (SELECT count(COLUMNS(*)) FROM types_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) n USING (column_name)
JOIN (UNPIVOT (SELECT coalesce(CAST(min(COLUMNS(*)) AS VARCHAR), '(none)') FROM types_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) lo USING (column_name)
JOIN (UNPIVOT (SELECT coalesce(CAST(max(COLUMNS(*)) AS VARCHAR), '(none)') FROM types_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) hi USING (column_name)
JOIN (UNPIVOT (SELECT md5(string_agg(coalesce('v' || CAST(COLUMNS(*) AS VARCHAR), 'n'), chr(31) ORDER BY id)) FROM types_parquet)
      ON COLUMNS(*) INTO NAME column_name VALUE v) h USING (column_name);
INSERT INTO summary
SELECT 'nulls', t.column_name, t.column_type, (SELECT count(*) FROM nulls_parquet), n.v, lo.v, hi.v, h.v
FROM (DESCRIBE FROM nulls_parquet) t
JOIN (UNPIVOT (SELECT count(COLUMNS(*)) FROM nulls_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) n USING (column_name)
JOIN (UNPIVOT (SELECT coalesce(CAST(min(COLUMNS(*)) AS VARCHAR), '(none)') FROM nulls_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) lo USING (column_name)
JOIN (UNPIVOT (SELECT coalesce(CAST(max(COLUMNS(*)) AS VARCHAR), '(none)') FROM nulls_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) hi USING (column_name)
JOIN (UNPIVOT (SELECT md5(string_agg(coalesce('v' || CAST(COLUMNS(*) AS VARCHAR), 'n'), chr(31) ORDER BY id)) FROM nulls_parquet)
      ON COLUMNS(*) INTO NAME column_name VALUE v) h USING (column_name);
INSERT INTO summary
SELECT 'join_left', t.column_name, t.column_type, (SELECT count(*) FROM join_left_parquet), n.v, lo.v, hi.v, h.v
FROM (DESCRIBE FROM join_left_parquet) t
JOIN (UNPIVOT (SELECT count(COLUMNS(*)) FROM join_left_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) n USING (column_name)
JOIN (UNPIVOT (SELECT coalesce(CAST(min(COLUMNS(*)) AS VARCHAR), '(none)') FROM join_left_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) lo USING (column_name)
JOIN (UNPIVOT (SELECT coalesce(CAST(max(COLUMNS(*)) AS VARCHAR), '(none)') FROM join_left_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) hi USING (column_name)
JOIN (UNPIVOT (SELECT md5(string_agg(coalesce('v' || CAST(COLUMNS(*) AS VARCHAR), 'n'), chr(31) ORDER BY id)) FROM join_left_parquet)
      ON COLUMNS(*) INTO NAME column_name VALUE v) h USING (column_name);
INSERT INTO summary
SELECT 'join_right', t.column_name, t.column_type, (SELECT count(*) FROM join_right_parquet), n.v, lo.v, hi.v, h.v
FROM (DESCRIBE FROM join_right_parquet) t
JOIN (UNPIVOT (SELECT count(COLUMNS(*)) FROM join_right_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) n USING (column_name)
JOIN (UNPIVOT (SELECT coalesce(CAST(min(COLUMNS(*)) AS VARCHAR), '(none)') FROM join_right_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) lo USING (column_name)
JOIN (UNPIVOT (SELECT coalesce(CAST(max(COLUMNS(*)) AS VARCHAR), '(none)') FROM join_right_parquet) ON COLUMNS(*) INTO NAME column_name VALUE v) hi USING (column_name)
JOIN (UNPIVOT (SELECT md5(string_agg(coalesce('v' || CAST(COLUMNS(*) AS VARCHAR), 'n'), chr(31) ORDER BY id)) FROM join_right_parquet)
      ON COLUMNS(*) INTO NAME column_name VALUE v) h USING (column_name);
COPY (FROM summary ORDER BY dataset ASC, column_name ASC) TO 'summary.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
SELECT CASE WHEN count(DISTINCT row_group_id) <> 3 THEN error('datasets: nulls.parquet has ' || count(DISTINCT row_group_id) || ' row groups, not 3') END
FROM parquet_metadata('a/nulls.parquet');

-- The summary just written, byte for byte the committed golden (a change
-- to the generator, or to how this DuckDB reads Parquet, shows in review).
SELECT CASE WHEN (SELECT content FROM read_blob('summary.tsv')) IS DISTINCT FROM (SELECT content FROM read_blob('golden/summary.tsv'))
    THEN error('datasets: summary.tsv differs from golden/summary.tsv') END;
