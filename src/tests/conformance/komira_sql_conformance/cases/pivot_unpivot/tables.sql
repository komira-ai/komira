-- The PIVOT / UNPIVOT corpus's tables. SALES is long data: a region with two
-- products, one with the same product twice, one whose only product no case
-- lists (pad), a NULL amount, a NULL product and a NULL region. P holds a
-- DOUBLE price per region and product. Q keys BIGINT values by an INTEGER
-- group and a BIGINT quarter number. W is wide data: three BIGINT quarters
-- with NULLs (one row all NULL) and a VARCHAR note. EMPTY holds no row.
-- A DOUBLE is a quoted literal cast to its type.
CREATE TABLE SALES (region VARCHAR, product VARCHAR, amount BIGINT);
INSERT INTO SALES VALUES
    ('east', 'pen', 10),
    ('east', 'ink', 5),
    ('west', 'pen', 7),
    ('west', 'pen', 3),
    ('north', 'ink', 9),
    ('south', 'pad', 4),
    ('east', 'ink', NULL),
    ('north', NULL, 6),
    (NULL, 'pen', 2);
CREATE TABLE P (region VARCHAR, product VARCHAR, price DOUBLE);
INSERT INTO P VALUES
    ('east', 'pen', '1.5'::DOUBLE),
    ('east', 'pen', '2.25'::DOUBLE),
    ('east', 'ink', '-0.5'::DOUBLE),
    ('west', 'ink', NULL),
    ('west', 'pad', '8.0'::DOUBLE);
CREATE TABLE Q (y INTEGER, q BIGINT, v BIGINT);
INSERT INTO Q VALUES
    (7, 1, 5),
    (7, 2, 6),
    (8, 1, 7),
    (8, 4, 1);
CREATE TABLE W (name VARCHAR, q1 BIGINT, q2 BIGINT, q3 BIGINT, note VARCHAR);
INSERT INTO W VALUES
    ('Ana', 10, 20, 30, 'a'),
    ('Bo', 5, NULL, 7, NULL),
    ('Cy', NULL, NULL, NULL, 'c'),
    ('Di', -1, 0, 9000000000, '');
CREATE TABLE EMPTY (region VARCHAR, product VARCHAR, amount BIGINT);
