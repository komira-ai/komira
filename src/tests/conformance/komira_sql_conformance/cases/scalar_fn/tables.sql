-- Scalar-function fixture T: a key k, two strings (s, u) with empty, NULL, accented,
-- equal-length and transposed pairs, two timestamps (t, v), two BIGINT operands (m, n)
-- with every sign pairing, a zero divisor and a value beyond 32 bits, and a DOUBLE d
-- chosen so that log, gamma, cbrt and the inverse trig functions each differ from their
-- look-alikes. Row 4 is NULL in s, t, m, v and d. A DOUBLE is a quoted literal cast to DOUBLE.
-- Calendar columns for make_date, last_day and make_timestamp: yr, mo, dy, hr, mi (BIGINT),
-- a seconds DOUBLE sec and a DATE dt. Each of yr, mo, dy, hr, mi and sec is NULL in at least one
-- row; the rows hold a leap February 29 in three leap years (one a century leap year) and a
-- February 28 in a century year that is not a leap year, a 24:00 hour, two rows of 60 seconds,
-- and seconds finer than a microsecond (rows 8, 10, 11 and 12). dt holds a date in a leap and a
-- non-leap February, the first and last supported years, and DuckDB's infinity and -infinity.
CREATE TABLE T (k INTEGER, s VARCHAR, u VARCHAR, t TIMESTAMP, m BIGINT, n BIGINT, v TIMESTAMP, d DOUBLE, yr BIGINT, mo BIGINT, dy BIGINT, hr BIGINT, mi BIGINT, sec DOUBLE, dt DATE);
INSERT INTO T VALUES
    (0, '', '', TIMESTAMP '2015-09-04 12:30:45.123456', 17, 5, TIMESTAMP '2015-01-01 00:00:00.000000', '0.0'::DOUBLE, 2024, 2, 29, 0, 0, '0.0'::DOUBLE, DATE '2024-02-10'),
    (1, 'abc', 'abd', TIMESTAMP '2015-09-04 12:30:45.000000', -17, 5, TIMESTAMP '2015-09-04 12:30:45.000000', '1.0'::DOUBLE, 2028, 2, 29, 23, 59, '59.999999'::DOUBLE, DATE '2028-02-29'),
    (2, '  Hello ', '  Hello ', TIMESTAMP '2015-09-04 00:00:00.000001', 17, -5, TIMESTAMP '2014-12-31 23:59:59.999999', '100.0'::DOUBLE, 2000, 2, 29, 12, 30, '45.5'::DOUBLE, DATE '2000-02-01'),
    (3, 'Ünïcodé', 'Ünïcodé', TIMESTAMP '1999-12-31 23:59:59.999999', -17, -5, TIMESTAMP '2000-02-29 12:00:00.000000', '-8.0'::DOUBLE, 2100, 2, 28, 24, 0, '0.0'::DOUBLE, DATE '2100-02-15'),
    (4, NULL, 'abc', NULL, NULL, 3, NULL, NULL, NULL, 3, 1, 1, 2, '3.0'::DOUBLE, NULL),
    (5, 'kitten', 'sittin', TIMESTAMP '2000-01-01 00:00:00.000000', 0, 4, TIMESTAMP '1999-12-31 23:59:59.999999', '0.5'::DOUBLE, 2015, NULL, 31, 6, 7, '8.0'::DOUBLE, 'infinity'::DATE),
    (6, 'flaw', 'lawn', TIMESTAMP '2015-02-28 13:45:30.500000', 7, NULL, TIMESTAMP '2015-03-01 00:00:00.000000', '8.0'::DOUBLE, 2029, 12, NULL, 23, 59, '60.0'::DOUBLE, '-infinity'::DATE),
    (7, 'a', 'b', TIMESTAMP '2015-06-15 08:00:00.000123', 9, 0, TIMESTAMP '2015-06-15 08:00:00.000123', '5.0'::DOUBLE, 2015, 12, 31, 23, 59, '60.0'::DOUBLE, DATE '2015-11-30'),
    (8, 'ab', 'ba', TIMESTAMP '2015-06-15 08:00:59.999000', 4294967296, 3, TIMESTAMP '2014-06-15 08:00:59.999000', '-0.5'::DOUBLE, 1, 1, 1, 0, NULL, '0.0000005'::DOUBLE, DATE '0001-01-01'),
    (9, 'a,b', 'a,c', TIMESTAMP '2015-09-06 11:22:33.456789', -1, 2, TIMESTAMP '2015-09-06 11:22:33.456789', '1000.0'::DOUBLE, 9999, 12, 31, 23, 59, NULL, DATE '9999-12-31'),
    (10, 'Ünïcodé', 'Unicode', TIMESTAMP '2015-04-01 06:07:08.090000', 12, 7, TIMESTAMP '2015-03-31 06:07:08.090000', '2.0'::DOUBLE, 1970, 1, 1, NULL, 0, '0.0000015'::DOUBLE, DATE '1970-01-01'),
    (11, 'abcde', 'abzzzzzzz', TIMESTAMP '2015-05-02 17:18:19.202122', -3, 11, TIMESTAMP '2015-05-01 17:18:19.202122', '-0.25'::DOUBLE, 1969, 12, 31, 23, 59, '59.9999995'::DOUBLE, DATE '1969-12-31'),
    (12, 'abcdefgh', 'abcdeXXX', TIMESTAMP '2015-07-03 01:02:03.040506', 6, -2, TIMESTAMP '2015-07-02 01:02:03.040506', '0.75'::DOUBLE, 2024, 4, 30, 7, 8, '9.0000025'::DOUBLE, DATE '2024-04-30');
