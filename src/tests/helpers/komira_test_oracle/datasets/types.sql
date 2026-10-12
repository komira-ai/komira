-- `types`: the nullable type matrix, 256 rows. Each column starts with its
-- special values (the extremes of its type, signed zero, the least
-- subnormal, NaN and the infinities in their own columns, the first and
-- last instant), then drawn values with NULL on every eighth row
-- (gen.sql), so every column holds NULLs and values. `id` is the row
-- number, not nullable.
CREATE TABLE types AS
SELECT
    CAST(i AS BIGINT) AS id,
    cell(i, CAST([-128, 127, 0, -1, 1, NULL] AS TINYINT[]), CAST(CAST(draw(i, 1) % 256 AS INTEGER) - 128 AS TINYINT)) AS i8,
    cell(i, CAST([-32768, 32767, 0, -1, 1, NULL] AS SMALLINT[]), CAST(CAST(draw(i, 2) % 65536 AS INTEGER) - 32768 AS SMALLINT)) AS i16,
    cell(i, CAST([-2147483648, 2147483647, 0, -1, 1, NULL] AS INTEGER[]), CAST(CAST(draw(i, 3) % 4294967296 AS BIGINT) - 2147483648 AS INTEGER)) AS i32,
    cell(i, CAST([-9223372036854775808, 9223372036854775807, 0, -1, 1, NULL] AS BIGINT[]), CAST(CAST(draw(i, 4) AS HUGEINT) - 9223372036854775808 AS BIGINT)) AS i64,
    cell(i, CAST([0, 255, 1, NULL] AS UTINYINT[]), CAST(draw(i, 5) % 256 AS UTINYINT)) AS u8,
    cell(i, CAST([0, 65535, 1, NULL] AS USMALLINT[]), CAST(draw(i, 6) % 65536 AS USMALLINT)) AS u16,
    cell(i, CAST([0, 4294967295, 1, NULL] AS UINTEGER[]), CAST(draw(i, 7) % 4294967296 AS UINTEGER)) AS u32,
    cell(i, CAST([0, 18446744073709551615, 1, NULL] AS UBIGINT[]), CAST(draw(i, 8) AS UBIGINT)) AS u64,
    cell(i, CAST(['-0.0', '0.0', '1.4e-45', '1.1754944e-38', '3.4028235e38', '-3.4028235e38', '0.1', NULL] AS FLOAT[]),
        CAST(float_text(i, 10, 9, -50, 80) AS FLOAT)) AS f32,
    cell(i, CAST(['-0.0', '0.0', '5e-324', '-5e-324', '2.2250738585072014e-308', '1.7976931348623157e308',
                  '-1.7976931348623157e308', '0.1', '1.5', NULL] AS DOUBLE[]),
        CAST(float_text(i, 20, 17, -330, 622) AS DOUBLE)) AS f64,
    cell(i, CAST(['nan', 'inf', '-inf', '-0.0', '1.0', NULL] AS FLOAT[]),
        CASE WHEN draw(i, 30) % 2 = 0 THEN CAST((['nan', 'inf', '-inf'])[CAST(draw(i, 31) % 3 AS BIGINT) + 1] AS FLOAT)
             ELSE CAST(float_text(i, 32, 9, -50, 80) AS FLOAT) END) AS f32_special,
    cell(i, CAST(['nan', 'inf', '-inf', '-0.0', '1.0', NULL] AS DOUBLE[]),
        CASE WHEN draw(i, 40) % 2 = 0 THEN CAST((['nan', 'inf', '-inf'])[CAST(draw(i, 41) % 3 AS BIGINT) + 1] AS DOUBLE)
             ELSE CAST(float_text(i, 42, 17, -330, 622) AS DOUBLE) END) AS f64_special,
    cell(i, CAST(['9999999.99', '-9999999.99', '0', '0.01', '-0.01', NULL] AS DECIMAL(9,2)[]),
        CAST(dec_text(CAST(draw(i, 50) % 1999999999 AS HUGEINT) - 999999999, 2) AS DECIMAL(9,2))) AS dec_9_2,
    cell(i, CAST(['9999999999999999999999999999.9999999999', '-9999999999999999999999999999.9999999999',
                  '0', '0.0000000001', '-0.0000000001', NULL] AS DECIMAL(38,10)[]),
        CAST(dec_text(CAST((draw(i, 51) * CAST(18446744073709551616 AS UHUGEINT) + draw(i, 52)) % CAST(100000000000000000000000000000000000000 AS UHUGEINT) AS HUGEINT)
                      * (CASE WHEN draw(i, 53) % 2 = 0 THEN -1 ELSE 1 END), 10) AS DECIMAL(38,10))) AS dec_38_10,
    cell(i, ['', ' ', 'a', 'é', '世界', '😀', '\N', 'NULL', 'null', 'NaN', 'nan', 'a,b', 'say "hi"',
             'line' || chr(10) || 'break', 'tab' || chr(9) || 'here', 'back\slash', 'cr' || chr(13) || 'here',
             ' lead', 'trail ', NULL], draw_text(i, 60)) AS str,
    cell(i, [CAST('' AS BLOB), CAST('\x00' AS BLOB), CAST('abc' AS BLOB), CAST('a,"\x0A' AS BLOB), encode('é'), NULL],
        encode(draw_text(i, 70))) AS bin,
    cell(i, [CAST('\xFF' AS BLOB), CAST('\x80\x00' AS BLOB), CAST('\xC0\xAF' AS BLOB), CAST('\xED\xA0\x80' AS BLOB), CAST('\xFE\xFF' AS BLOB), NULL],
        unhex((SELECT string_agg(printf('%02x', CAST(draw(i * 16 + p, 81) % 256 AS INTEGER)), '' ORDER BY p)
            FROM range(CAST(draw(i, 80) % 8 AS BIGINT) + 1) AS t(p)))) AS bin_raw,
    cell(i, CAST(['1970-01-01', '1969-12-31', '0001-01-01', '9999-12-31', NULL] AS DATE[]),
        DATE '1900-01-01' + CAST(draw(i, 90) % 73049 AS INTEGER)) AS date32,
    -- Instants from 1900 to 2100 between the specials, in each unit. The
    -- epoch microseconds of 1900-01-01 and 2100-01-01 are -2208988800e6
    -- and 4102444800e6.
    cell(i, CAST(['1970-01-01 00:00:00', '1969-12-31 23:59:59', '1970-01-01 00:00:01', '0001-01-01 00:00:00', '9999-12-31 23:59:59', NULL] AS TIMESTAMP_S[]),
        CAST(make_timestamp(-2208988800000000 + CAST(draw(i, 100) % 6311433600 AS BIGINT) * 1000000) AS TIMESTAMP_S)) AS ts_s,
    cell(i, CAST(['1970-01-01 00:00:00', '1969-12-31 23:59:59.999', '1970-01-01 00:00:00.001', '0001-01-01 00:00:00', '9999-12-31 23:59:59.999', NULL] AS TIMESTAMP_MS[]),
        CAST(make_timestamp(-2208988800000000 + CAST(draw(i, 101) % 6311433600000 AS BIGINT) * 1000) AS TIMESTAMP_MS)) AS ts_ms,
    cell(i, CAST(['1970-01-01 00:00:00', '1969-12-31 23:59:59.999999', '1970-01-01 00:00:00.000001', '0001-01-01 00:00:00', '9999-12-31 23:59:59.999999', NULL] AS TIMESTAMP[]),
        make_timestamp(-2208988800000000 + CAST(draw(i, 102) % 6311433600000000 AS BIGINT))) AS ts_us,
    cell(i, [make_timestamp_ns(0), make_timestamp_ns(-1), make_timestamp_ns(1), make_timestamp_ns(-9223286400000000000), make_timestamp_ns(9223372036854775806), NULL],
        make_timestamp_ns(CAST(CAST(-2208988800000000000 AS HUGEINT) + CAST(draw(i, 103) % 6311433600000000000 AS HUGEINT) AS BIGINT))) AS ts_ns,
    cell(i, CAST(['1970-01-01 00:00:00+00', '1970-01-01 05:30:00+05:30', '0001-01-01 00:00:00+00', '9999-12-31 23:59:59.999999+00', NULL] AS TIMESTAMPTZ[]),
        CAST(make_timestamp(-2208988800000000 + CAST(draw(i, 104) % 6311433600000000 AS BIGINT)) AS TIMESTAMPTZ)) AS ts_tz,
    cell(i, [true, false, NULL], draw(i, 110) % 2 = 0) AS "bool"
FROM range(256) AS r(i);
