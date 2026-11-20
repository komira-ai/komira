-- Tables for predicate and three-valued logic cases. T holds twelve rows with a
-- NULL string and NULL ints, an empty string, literal % _ and backslash in the
-- data, a non-ASCII string, and all nine combinations of two nullable booleans
-- (b1, b2) on its first nine rows. S is a small key list that contains a NULL.
CREATE TABLE T (k BIGINT, s VARCHAR, i BIGINT, j BIGINT, b1 BOOLEAN, b2 BOOLEAN);
INSERT INTO T VALUES
    (0, NULL, NULL, 1, TRUE, TRUE),
    (1, '', 1, 1, TRUE, FALSE),
    (2, 'abc', 2, NULL, TRUE, NULL),
    (3, 'ABC', 3, 3, FALSE, TRUE),
    (4, '100%', 4, 2, FALSE, FALSE),
    (5, 'a_b', 5, NULL, FALSE, NULL),
    (6, 'a%c', 10, 10, NULL, TRUE),
    (7, 'Ünïcodé', 20, 5, NULL, FALSE),
    (8, 'straße', NULL, NULL, NULL, NULL),
    (9, 'x\y', 30, 30, TRUE, NULL),
    (10, 'aXc', -5, 0, FALSE, TRUE),
    (11, 'ab', 0, -5, TRUE, FALSE);
CREATE TABLE S (v BIGINT);
INSERT INTO S VALUES
    (2),
    (3),
    (NULL),
    (30);
