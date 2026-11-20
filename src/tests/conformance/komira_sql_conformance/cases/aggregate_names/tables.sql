-- Table for plain aggregate spellings over groups. N has three groups: one with
-- some NULLs, one all negative, one all NULL; int, DOUBLE, string and DATE
-- columns, so min/max/avg/mean/count differ by column and by group.
CREATE TABLE N (k BIGINT, g BIGINT, i BIGINT, f DOUBLE, s VARCHAR, d DATE);
INSERT INTO N VALUES
    (0, 1, 10, '1.5'::DOUBLE, 'apple', DATE '2021-03-04'),
    (1, 1, 20, '2.5'::DOUBLE, 'Banana', DATE '1999-12-31'),
    (2, 1, 30, '3.5'::DOUBLE, 'cherry', DATE '2024-06-15'),
    (3, 1, NULL, NULL, NULL, NULL),
    (4, 2, -8, '-1.25'::DOUBLE, 'date', DATE '2000-01-01'),
    (5, 2, -4, '-2.25'::DOUBLE, 'Elder', DATE '2024-02-29'),
    (6, 2, -6, '-3.5'::DOUBLE, 'fig', DATE '2024-01-01'),
    (7, 3, NULL, NULL, NULL, NULL),
    (8, 3, NULL, NULL, NULL, NULL);
