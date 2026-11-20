-- Window-frame tables over small integers.
-- F: two partitions of different sizes (5 and 3 rows) with a tie-free order key in each,
-- and values that include negatives so sliding sums, minima and maxima all move.
-- T: one implicit partition whose order key has ties (peer groups of 3, 2, 1, 2).
CREATE TABLE F (k BIGINT, g BIGINT, o BIGINT, v BIGINT);
INSERT INTO F VALUES
    (0, 1, 10, 5),
    (1, 1, 20, -2),
    (2, 1, 30, 7),
    (3, 1, 40, 3),
    (4, 1, 50, 8),
    (5, 2, 10, 4),
    (6, 2, 20, 9),
    (7, 2, 30, -1);
CREATE TABLE T (k BIGINT, o BIGINT, v BIGINT);
INSERT INTO T VALUES
    (0, 10, 5),
    (1, 10, -3),
    (2, 10, 6),
    (3, 20, 7),
    (4, 20, 2),
    (5, 30, 4),
    (6, 40, -8),
    (7, 40, 9);
