-- The small tables the regression cases (cases/regress_*.sql) read, each
-- written by the pinned DuckDB as one Parquet file and registered under its
-- file name by both engines (sql/tables.sql here, runner.mojo's
-- open_session in komira). Every value is a literal or a function of a
-- range() row number: no random() and no clock. Each table is shaped so
-- that one engine defect changes the answer; the case that reads it says
-- which.

-- A global aggregate over a scan: v = 0..95, f = v + 0.5.
CREATE TABLE agg_scalar AS
SELECT CAST(i AS BIGINT) AS v, CAST(i AS DOUBLE) + 0.5 AS f FROM range(96) AS r(i);

-- Groups for count(<column>): group 1 holds 0, 1, 2; group 2 a NULL and 7;
-- groups 3 and 5 only NULLs (count 0, never a dropped group).
CREATE TABLE count_groups AS
SELECT * FROM (VALUES
    (CAST(1 AS BIGINT), CAST(0 AS BIGINT)), (1, 1), (1, 2),
    (2, NULL), (2, 7),
    (3, NULL),
    (5, NULL), (5, NULL), (5, NULL)
) AS t(id, val);

-- A LEFT JOIN pair: customers, and orders of some of them (customer 4 has
-- none, customer 6 only an order whose comment filters it out).
CREATE TABLE lj_customer AS
SELECT CAST(i AS BIGINT) AS c_id FROM range(1, 7) AS r(i);
CREATE TABLE lj_orders AS
SELECT * FROM (VALUES
    (CAST(100 AS BIGINT), CAST(1 AS BIGINT), 'plain'),
    (101, 1, 'plain'),
    (102, 2, 'plain'),
    (103, 3, 'plain'),
    (104, 3, 'plain'),
    (105, 3, 'special requests'),
    (106, 5, 'plain'),
    (107, 6, 'special requests')
) AS t(o_id, o_cust, o_comment);

-- count(DISTINCT) per group: duplicates, a NULL beside values, a group of
-- one value repeated, and a group of NULLs only.
CREATE TABLE distinct_pairs AS
SELECT * FROM (VALUES
    (CAST(1 AS BIGINT), CAST(10 AS BIGINT)), (1, 10), (1, 20),
    (2, 30), (2, 30), (2, NULL),
    (3, 5), (3, 5), (3, 5),
    (4, NULL), (4, NULL)
) AS t(key, val);

-- The two sides of a cross join: a = 1, 2, 3 and b = 10, 20 (and 20 twice,
-- so a distinct count across the join is less than the row count).
CREATE TABLE cross_a AS
SELECT * FROM (VALUES (CAST(1 AS BIGINT)), (2), (3)) AS t(a);
CREATE TABLE cross_b AS
SELECT * FROM (VALUES (CAST(1 AS BIGINT), CAST(10 AS BIGINT)), (2, 20), (3, 20)) AS t(bid, b);

-- A string-key join pair: alice twice on the probe side, bob and a NULL
-- name with no match, '' on both sides, dave only on the build side.
CREATE TABLE skey_probe AS
SELECT * FROM (VALUES
    ('alice', CAST(100 AS BIGINT)),
    ('bob', 200),
    ('charlie', 300),
    ('alice', 150),
    ('', 50),
    (NULL, 400)
) AS t(name, amount);
CREATE TABLE skey_build AS
SELECT * FROM (VALUES
    ('alice', CAST(10 AS BIGINT), CAST(1 AS BIGINT)),
    ('charlie', 30, 3),
    ('dave', 40, 4),
    ('', 0, 0)
) AS t(rname, region_id, priority);

-- Aggregates over computed columns, before and after joins, all BIGINT (a
-- grouped SUM folds integers; the case is the computed input, not the
-- type); three rows per k, b not a linear function of a, so corr(a, b) is
-- not 1.
CREATE TABLE derived_l AS
SELECT * FROM (VALUES
    (CAST(1 AS BIGINT), CAST(1 AS BIGINT), CAST(10 AS BIGINT)),
    (2, 2, 20),
    (1, 3, 30),
    (2, 4, 40),
    (1, 5, 10),
    (2, 1, 50)
) AS t(k, a, b);
CREATE TABLE derived_r AS
SELECT * FROM (VALUES (CAST(1 AS BIGINT), CAST(100 AS BIGINT)), (2, 200)) AS t(k, c);
-- A profit chain: a line's price less its discount (in percent) less its
-- supply cost times its quantity, in cents.
CREATE TABLE profit_lineitem AS
SELECT * FROM (VALUES
    (CAST(1 AS BIGINT), CAST(10 AS BIGINT), CAST(100 AS BIGINT), CAST(25 AS BIGINT), CAST(5 AS BIGINT)),
    (2, 20, 200, 50, 5),
    (1, 10, 300, 25, 10),
    (2, 20, 400, 50, 10)
) AS t(li_part, li_supp, li_price, li_pct, li_quantity);
CREATE TABLE profit_partsupp AS
SELECT * FROM (VALUES
    (CAST(1 AS BIGINT), CAST(10 AS BIGINT), CAST(3 AS BIGINT)),
    (2, 20, 7),
    (1, 20, 1000)
) AS t(ps_part, ps_supp, ps_cost);
CREATE TABLE profit_supplier AS
SELECT * FROM (VALUES (CAST(10 AS BIGINT), CAST(1995 AS BIGINT)), (20, 1996)) AS t(s_supp, s_year);

-- LEFT and anti joins over INT64 keys: probe keys 0..7, build keys 0..3.
CREATE TABLE pad_probe AS
SELECT CAST(i AS BIGINT) AS key, CAST(i * 100 AS BIGINT) AS left_val FROM range(8) AS r(i);
CREATE TABLE pad_build AS
SELECT CAST(i AS BIGINT) AS key, CAST(i * 1000 + 7 AS BIGINT) AS right_val FROM range(4) AS r(i);

-- Many-to-many fan-out: 100 probe rows per key against 10 build rows per
-- key, ten keys; every payload distinct, so each output row names one
-- probe row and one build row.
CREATE TABLE fan_probe AS
SELECT CAST(i // 100 AS BIGINT) AS jkey, CAST(i AS BIGINT) AS left_val FROM range(1000) AS r(i);
CREATE TABLE fan_build AS
SELECT CAST(i // 10 AS BIGINT) AS jkey, CAST(i AS BIGINT) AS right_val FROM range(100) AS r(i);

-- FULL JOIN: keys on both sides, on the left only (4), on the right only
-- (3, 5), and a left key matching two right rows (1).
CREATE TABLE full_l AS
SELECT * FROM (VALUES (CAST(1 AS BIGINT), CAST(10 AS BIGINT)), (2, 20), (4, 40)) AS t(lk, lv);
CREATE TABLE full_r AS
SELECT * FROM (VALUES
    (CAST(1 AS BIGINT), CAST(101 AS BIGINT)), (1, 102), (2, 200), (3, 300), (5, 500)
) AS t(rk, rv);

-- IN (subquery), correlated and nested: an outer table whose rows each
-- fail the correlated IN a different way, and a supplier/partsupp/part
-- chain for the nested form.
CREATE TABLE in_outer AS
SELECT * FROM (VALUES
    (CAST(10 AS BIGINT), CAST(1 AS BIGINT)),
    (20, 1),
    (30, 2),
    (40, 9),
    (99, 2),
    (10, 2)
) AS t(k, c);
CREATE TABLE in_inner AS
SELECT * FROM (VALUES (CAST(10 AS BIGINT), CAST(1 AS BIGINT)), (99, 2)) AS t(i, j);
CREATE TABLE in_supplier AS
SELECT CAST(i AS BIGINT) AS s_suppkey FROM range(1, 5) AS r(i);
CREATE TABLE in_partsupp AS
SELECT * FROM (VALUES
    (CAST(10 AS BIGINT), CAST(1 AS BIGINT)), (20, 2), (30, 3), (30, 1)
) AS t(ps_partkey, ps_suppkey);
CREATE TABLE in_part AS
SELECT * FROM (VALUES (CAST(10 AS BIGINT)), (30)) AS t(p_partkey);

-- Floats across row groups (6000 rows, groups of 2048 rows): f64 and f32
-- distinct per row (so the writer stores them PLAIN), the first rows NaN,
-- +inf, -inf, -0.0 and 0.0; f64_dict and f32_dict with 11 and 7 values
-- (so the writer dictionary-encodes them).
CREATE TABLE floats AS
SELECT
    CAST(i AS BIGINT) AS i,
    CAST(i % 50 AS BIGINT) AS c0,
    CASE WHEN i < 5 THEN CAST(['nan', 'inf', '-inf', '-0.0', '0.0'][i + 1] AS DOUBLE)
         ELSE CAST(i AS DOUBLE) * 1.5 + 0.25 END AS f64,
    CASE WHEN i < 5 THEN CAST(['nan', 'inf', '-inf', '-0.0', '0.0'][i + 1] AS FLOAT)
         ELSE CAST(CAST(i AS DOUBLE) * 0.25 - 3.0 AS FLOAT) END AS f32,
    CAST(i % 11 AS DOUBLE) + 0.5 AS f64_dict,
    CAST(CAST(i % 7 AS DOUBLE) - 2.5 AS FLOAT) AS f32_dict
FROM range(6000) AS r(i);

-- Text read as numbers (cases cast_text_*): ids 0 to 20 are spellings
-- every one of BIGINT, INTEGER and DOUBLE reads (a sign, whitespace, a
-- fraction rounded half away from zero, an exponent, an underscore); from
-- id 100, the edges of DuckDB's text-to-number grammar: past each range,
-- hexadecimal and binary, an exponent applied DuckDB's way, underscores,
-- NaN and the infinities, a value rounded or out of range as a float, text
-- that is no number, and a NULL.
CREATE TABLE cast_text AS
SELECT * FROM (VALUES
    (CAST(0 AS BIGINT), CAST('0' AS VARCHAR)),
    (1, '12'),
    (2, '-7'),
    (3, ' 12 '),
    (4, '3.5'),
    (5, '2.5'),
    (6, '-2.5'),
    (7, '0.5'),
    (8, '-0.5'),
    (9, '1.49999'),
    (10, '1e3'),
    (11, '1.5e1'),
    (12, '+5'),
    (13, '.5'),
    (14, '5.'),
    (15, '00012'),
    (16, '1_000'),
    (17, '25e-1'),
    (18, '1e-1'),
    (19, '1.45e1'),
    (20, '-0'),
    (100, '9223372036854775807'),
    (101, '9223372036854775808'),
    (102, '-9223372036854775808'),
    (103, '9223372036854775807.4'),
    (104, '9223372036854775807.5'),
    (105, '-9223372036854775808.4'),
    (106, '-9223372036854775808.5'),
    (107, '2147483647.5'),
    (108, '2147483646.5'),
    (109, '-2147483648.5'),
    (110, '2147483648'),
    (111, '-2147483649'),
    (112, '30000000000e-2'),
    (113, '0x1F'),
    (114, '0X1f'),
    (115, '0b101'),
    (116, '0B11'),
    (117, '0x7FFFFFFFFFFFFFFF'),
    (118, '0xFFFFFFFFFFFFFFFF'),
    (119, '0x80000000'),
    (120, ' 0x1F'),
    (121, '0x1F '),
    (122, '-0x1F'),
    (123, '+0x1F'),
    (124, '0x1_F'),
    (125, '0x_1F'),
    (126, '0x'),
    (127, '0b'),
    (128, '0x1.5'),
    (129, '5e-2'),
    (130, '-5e-2'),
    (131, '0.5e-1'),
    (132, '0.55e-1'),
    (133, '0.05e-1'),
    (134, '12.35e-1'),
    (135, '1.050e1'),
    (136, '1.9000000000000000000e0'),
    (137, '1.900000000000000000e0'),
    (138, '1e19'),
    (139, '9.3e18'),
    (140, '1e-99999'),
    (141, '5e-32768'),
    (142, '1e32767'),
    (143, '0e40000'),
    (144, '1e2.'),
    (145, '1e2.5'),
    (146, '1e '),
    (147, '1e+ '),
    (148, '- '),
    (149, '+ '),
    (150, '1_0.5'),
    (151, '1.5_5'),
    (152, '1__0'),
    (153, '_1'),
    (154, '1_'),
    (155, '1._5'),
    (156, '1_.5'),
    (157, '1e1_0'),
    (158, '1e_1'),
    (159, '1.5_e1'),
    (160, ''),
    (161, '   '),
    (162, 'abc'),
    (163, '1 2'),
    (164, '- 5'),
    (165, '1e'),
    (166, '1e+'),
    (167, 'nan'),
    (168, 'NaN'),
    (169, 'inf'),
    (170, '-Infinity'),
    (171, '+inf'),
    (172, 'nan(1)'),
    (173, 'nan()'),
    (174, 'infinit'),
    (175, 'infinityx'),
    (176, '1.2.3'),
    (177, '--1'),
    (178, '+-5'),
    (179, '-+5'),
    (180, '1,000'),
    (181, '.'),
    (182, '-'),
    (183, '-.'),
    (184, '-.5'),
    (185, '5.e1'),
    (186, '1e400'),
    (187, '-1e400'),
    (188, '1e-400'),
    (189, '-1e-400'),
    (190, '0.1'),
    (191, '123.456'),
    (192, '7.58'),
    (193, '9007199254740993'),
    (194, '1.7976931348623157e308'),
    (195, '1.7976931348623159e308'),
    (196, '4.9e-324'),
    (197, '2e-324'),
    (198, '2.2250738585072011e-308'),
    (199, '1.5E+0010'),
    (200, '123456789012345678901234567890'),
    (201, '0.000000000000000000000000000000000000000000000000001e51'),
    (202, chr(9) || '7' || chr(10)),
    (203, NULL)
) AS t(id, txt);

COPY agg_scalar TO 'agg_scalar.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY count_groups TO 'count_groups.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY lj_customer TO 'lj_customer.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY lj_orders TO 'lj_orders.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY distinct_pairs TO 'distinct_pairs.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY cross_a TO 'cross_a.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY cross_b TO 'cross_b.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY skey_probe TO 'skey_probe.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY skey_build TO 'skey_build.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY derived_l TO 'derived_l.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY derived_r TO 'derived_r.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY profit_lineitem TO 'profit_lineitem.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY profit_partsupp TO 'profit_partsupp.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY profit_supplier TO 'profit_supplier.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY pad_probe TO 'pad_probe.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY pad_build TO 'pad_build.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY fan_probe TO 'fan_probe.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY fan_build TO 'fan_build.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY full_l TO 'full_l.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY full_r TO 'full_r.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY in_outer TO 'in_outer.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY in_inner TO 'in_inner.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY in_supplier TO 'in_supplier.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY in_partsupp TO 'in_partsupp.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY in_part TO 'in_part.parquet' (FORMAT parquet, COMPRESSION snappy);
COPY (SELECT * FROM floats ORDER BY i ASC) TO 'floats.parquet' (FORMAT parquet, COMPRESSION snappy, ROW_GROUP_SIZE 2048);
COPY cast_text TO 'cast_text.parquet' (FORMAT parquet, COMPRESSION snappy);
