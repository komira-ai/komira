-- RANGE-frame tables.
-- R: two partitions (6 and 5 rows) whose integer order key has peer groups and a gap in each;
-- every v is positive. onull is the key with one NULL per partition, s a text key.
-- Q: the same shape with an integer key oi and a DOUBLE key af with fractional values.
CREATE TABLE R (k BIGINT, g BIGINT, o BIGINT, v BIGINT, onull BIGINT, s VARCHAR);
INSERT INTO R VALUES
    (0, 1, 10, 5, NULL, 'aa'),
    (1, 1, 10, 3, 10, 'aa'),
    (2, 1, 10, 7, 10, 'aa'),
    (3, 1, 11, 2, 11, 'bb'),
    (4, 1, 11, 9, 11, 'bb'),
    (5, 1, 20, 4, 20, 'cc'),
    (6, 2, 5, 6, NULL, 'pp'),
    (7, 2, 5, 1, 5, 'pp'),
    (8, 2, 6, 8, 6, 'qq'),
    (9, 2, 6, 2, 6, 'qq'),
    (10, 2, 9, 7, 9, 'rr');
CREATE TABLE Q (k BIGINT, g BIGINT, oi BIGINT, af DOUBLE, v BIGINT);
INSERT INTO Q VALUES
    (0, 1, 1, '0.25'::DOUBLE, 5),
    (1, 1, 1, '0.5'::DOUBLE, 3),
    (2, 1, 2, '1.0'::DOUBLE, 7),
    (3, 1, 2, '1.0'::DOUBLE, 2),
    (4, 1, 3, '1.5'::DOUBLE, 9),
    (5, 1, 6, '4.5'::DOUBLE, 4),
    (6, 2, 1, '0.5'::DOUBLE, 6),
    (7, 2, 1, '0.5'::DOUBLE, 1),
    (8, 2, 2, '1.25'::DOUBLE, 8),
    (9, 2, 2, '1.25'::DOUBLE, 2),
    (10, 2, 4, '3.0'::DOUBLE, 7);
