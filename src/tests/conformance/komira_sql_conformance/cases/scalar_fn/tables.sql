-- Scalar-function fixture T: a key k, two strings (s, u) with empty, NULL, accented,
-- equal-length and transposed pairs, two timestamps (t, v), two BIGINT operands (m, n)
-- with every sign pairing, a zero divisor and a value beyond 32 bits, and a DOUBLE d
-- chosen so that log, gamma, cbrt and the inverse trig functions each differ from their
-- look-alikes. Row 4 is NULL in s, t, m, v and d. A DOUBLE is a quoted literal cast to DOUBLE.
CREATE TABLE T (k INTEGER, s VARCHAR, u VARCHAR, t TIMESTAMP, m BIGINT, n BIGINT, v TIMESTAMP, d DOUBLE);
INSERT INTO T VALUES
    (0, '', '', TIMESTAMP '2015-09-04 12:30:45.123456', 17, 5, TIMESTAMP '2015-01-01 00:00:00.000000', '0.0'::DOUBLE),
    (1, 'abc', 'abd', TIMESTAMP '2015-09-04 12:30:45.000000', -17, 5, TIMESTAMP '2015-09-04 12:30:45.000000', '1.0'::DOUBLE),
    (2, '  Hello ', '  Hello ', TIMESTAMP '2015-09-04 00:00:00.000001', 17, -5, TIMESTAMP '2014-12-31 23:59:59.999999', '100.0'::DOUBLE),
    (3, 'Ünïcodé', 'Ünïcodé', TIMESTAMP '1999-12-31 23:59:59.999999', -17, -5, TIMESTAMP '2000-02-29 12:00:00.000000', '-8.0'::DOUBLE),
    (4, NULL, 'abc', NULL, NULL, 3, NULL, NULL),
    (5, 'kitten', 'sittin', TIMESTAMP '2000-01-01 00:00:00.000000', 0, 4, TIMESTAMP '1999-12-31 23:59:59.999999', '0.5'::DOUBLE),
    (6, 'flaw', 'lawn', TIMESTAMP '2015-02-28 13:45:30.500000', 7, NULL, TIMESTAMP '2015-03-01 00:00:00.000000', '8.0'::DOUBLE),
    (7, 'a', 'b', TIMESTAMP '2015-06-15 08:00:00.000123', 9, 0, TIMESTAMP '2015-06-15 08:00:00.000123', '5.0'::DOUBLE),
    (8, 'ab', 'ba', TIMESTAMP '2015-06-15 08:00:59.999000', 4294967296, 3, TIMESTAMP '2014-06-15 08:00:59.999000', '-0.5'::DOUBLE),
    (9, 'a,b', 'a,c', TIMESTAMP '2015-09-06 11:22:33.456789', -1, 2, TIMESTAMP '2015-09-06 11:22:33.456789', '1000.0'::DOUBLE),
    (10, 'Ünïcodé', 'Unicode', TIMESTAMP '2015-04-01 06:07:08.090000', 12, 7, TIMESTAMP '2015-03-31 06:07:08.090000', '2.0'::DOUBLE),
    (11, 'abcde', 'abzzzzzzz', TIMESTAMP '2015-05-02 17:18:19.202122', -3, 11, TIMESTAMP '2015-05-01 17:18:19.202122', '-0.25'::DOUBLE),
    (12, 'abcdefgh', 'abcdeXXX', TIMESTAMP '2015-07-03 01:02:03.040506', 6, -2, TIMESTAMP '2015-07-02 01:02:03.040506', '0.75'::DOUBLE);
-- Edge table E: a BIGINT i at 0, 1, -1, both extremes, the 32-bit extremes and NULL; a DOUBLE f
-- with 0.0, -0.0, halves either side of zero, NaN, both infinities, a value near the top
-- of the range and a subnormal negative; a DATE dt and a TIMESTAMP ts on a leap day,
-- either side of a year boundary (a Sunday 2028-12-31 and a Monday 2029-01-01), in ISO
-- week 53 of 2020, at the century years 1900, 2000 and 2100, and either side of the epoch;
-- JSON text j (nested, a JSON null, an array, a key holding a dot, a TAB, an empty string);
-- and tick counts us, ms, ns for make_timestamp. Row 11 is NULL in dt, ts and j; row 6 in i, us, ms, ns.
CREATE TABLE E (k INTEGER, i BIGINT, f DOUBLE, dt DATE, ts TIMESTAMP, j VARCHAR, us BIGINT, ms BIGINT, ns BIGINT);
INSERT INTO E VALUES
    (0, 0, '0.0'::DOUBLE, DATE '2024-02-29', TIMESTAMP '2024-02-29 23:59:59.999999', '{"a":1,"b":"x","c":{"d":2}}', 0, 0, 0),
    (1, 1, '-0.0'::DOUBLE, DATE '2028-12-31', TIMESTAMP '2028-12-31 23:59:59', '{"a":"y","b":null}', 1, 1, 1),
    (2, -1, '0.5'::DOUBLE, DATE '2029-01-01', TIMESTAMP '2029-01-01 00:00:00', '{"a":[1,2],"b":true}', -1, -1, -1),
    (3, 9223372036854775807, '-0.5'::DOUBLE, DATE '2021-01-03', TIMESTAMP '2021-01-03 12:00:00.5', '{"a.b":5,"a":{"b":6}}', 1700000000000000, 1700000000000, 1700000000123456789),
    (4, -9223372036854775807, '2.5'::DOUBLE, DATE '2021-01-04', TIMESTAMP '2021-01-04 00:00:00.000001', '{}', 951782400000000, 951782400000, 951782400000000001),
    (5, -9223372036854775808, '-2.5'::DOUBLE, DATE '2020-12-31', TIMESTAMP '2020-12-31 23:59:59.999999', '[1,2]', -86400000001, -86400001, -86400000000001),
    (6, NULL, 'nan'::DOUBLE, DATE '2000-02-29', TIMESTAMP '2000-02-29 12:00:00', '{"a":null}', NULL, NULL, NULL),
    (7, 4294967295, 'inf'::DOUBLE, DATE '1900-03-01', TIMESTAMP '1900-03-01 00:00:00', '{"b":"tab\there"}', 1, 1, 1),
    (8, -2147483648, '-inf'::DOUBLE, DATE '2100-02-01', TIMESTAMP '2100-02-28 06:00:00', '{"a":1.50}', 2, 2, 2),
    (9, 2147483647, '1.5'::DOUBLE, DATE '1970-01-01', TIMESTAMP '1970-01-01 00:00:00', '{"a":-0}', 3, 3, 3),
    (10, 12345, '-1.5'::DOUBLE, DATE '1969-12-31', TIMESTAMP '1969-12-31 23:59:59.999999', '{"b":"Ünïcodé"}', 4, 4, 4),
    (11, -255, '1e308'::DOUBLE, NULL, NULL, NULL, 5, 5, 5),
    (12, 255, '-1e-308'::DOUBLE, DATE '2015-01-04', TIMESTAMP '2015-01-04 23:00:00', '{"a":"","b":""}', 6, 6, 6);
