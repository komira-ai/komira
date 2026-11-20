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
