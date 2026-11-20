-- Three small tables. T has a key k, a group g, a DOUBLE v, a VARCHAR s that holds
-- an empty string, mixed case, repeats and a NULL, and a BIGINT n with a NULL.
-- U holds join keys j with values w. D holds a key and a DATE.
CREATE TABLE T (k BIGINT, g BIGINT, v DOUBLE, s VARCHAR, n BIGINT);
CREATE TABLE U (j BIGINT, w BIGINT);
CREATE TABLE D (dk BIGINT, d DATE);
INSERT INTO T VALUES
    (0, 0, '10.0'::DOUBLE, '', 1),
    (1, 0, '20.0'::DOUBLE, 'ab', 2),
    (2, 1, '30.0'::DOUBLE, 'AB', NULL),
    (3, 1, '40.0'::DOUBLE, NULL, 4),
    (4, 2, '50.0'::DOUBLE, 'zz', 9),
    (5, 2, '60.0'::DOUBLE, 'ab', 3);
INSERT INTO U VALUES
    (1, 100),
    (2, 200),
    (3, 300),
    (9, 900);
INSERT INTO D VALUES
    (0, DATE '2020-01-15'),
    (1, DATE '2021-02-10'),
    (2, DATE '2022-12-31'),
    (3, DATE '2023-06-15');
