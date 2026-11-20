-- Function-position fixture: T(k, s, i, g, f, t, n, bt) and U(j, w). s holds a NULL, an empty
-- string and two non-ASCII strings at different offsets; i holds the BIGINT minimum and maximum;
-- f holds 0.0, -0.0, inf, -inf and nan (quoted literals cast to DOUBLE keep the sign); g holds
-- exact squares; t holds timestamps with fractional seconds; bt holds true, false and NULL.
CREATE TABLE T (k BIGINT, s VARCHAR, i BIGINT, g DOUBLE, f DOUBLE, t TIMESTAMP, n BIGINT, bt BOOLEAN);
INSERT INTO T VALUES
    (0, NULL, 0, '0.0'::DOUBLE, '0.0'::DOUBLE, '2021-01-01 00:00:00'::TIMESTAMP, 0, true),
    (1, 'abc', 1, '1.0'::DOUBLE, '-0.0'::DOUBLE, '2021-03-04 05:06:07.123456'::TIMESTAMP, 1, false),
    (2, 'aéb', -5, '4.0'::DOUBLE, '2.5'::DOUBLE, '2022-07-15 23:59:59'::TIMESTAMP, 2, true),
    (3, '', 9223372036854775807, '9.0'::DOUBLE, 'inf'::DOUBLE, '2023-12-31 12:00:00'::TIMESTAMP, 3, NULL),
    (4, 'BCD', -9223372036854775808, '16.0'::DOUBLE, 'nan'::DOUBLE, '2020-02-29 06:30:00'::TIMESTAMP, 4, true),
    (5, 'zb', 42, '25.0'::DOUBLE, '-inf'::DOUBLE, '2019-11-05 00:00:01'::TIMESTAMP, 5, false),
    (6, ' pad ', -1, '2.25'::DOUBLE, '-7.5'::DOUBLE, '2024-06-30 18:45:30.000001'::TIMESTAMP, 6, true),
    (7, 'ábc', 7, '6.25'::DOUBLE, '3.25'::DOUBLE, '2021-03-04 05:06:07'::TIMESTAMP, 0, NULL);
CREATE TABLE U (j BIGINT, w VARCHAR);
INSERT INTO U VALUES
    (0, 'u0'),
    (1, 'u1'),
    (2, 'u2'),
    (3, 'u3'),
    (4, 'u4'),
    (5, 'u5'),
    (6, 'u6'),
    (7, 'u7');
