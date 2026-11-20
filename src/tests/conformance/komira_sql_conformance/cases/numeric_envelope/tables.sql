-- Six rows with the same small numbers (7 to 23) held as BIGINT, INTEGER, DOUBLE and
-- FLOAT, paired with a shuffled copy, so mixed-type comparisons and CASE arms
-- have rows that win each way. Two string columns for CASE over text.
-- The p_ and q_ columns hold 2^24+1, 2^24 and 2^24-1: exact in DOUBLE and the
-- integer types but not in FLOAT, so the type a comparison runs in changes the answer.
-- Floats are quoted literals cast to the column type so -0.0 keeps its sign.
CREATE TABLE t (k BIGINT, a_i64 BIGINT, b_i64 BIGINT, a_i32 INTEGER, b_i32 INTEGER, a_f64 DOUBLE, b_f64 DOUBLE, a_f32 FLOAT, b_f32 FLOAT, s1 VARCHAR, s2 VARCHAR, p_f32 FLOAT, p_f64 DOUBLE, p_i64 BIGINT, p_i32 INTEGER, q_f32 FLOAT);
INSERT INTO t VALUES
    (1, 7, 13, 7, 13, '7.0'::DOUBLE, '13.0'::DOUBLE, '7.0'::FLOAT, '13.0'::FLOAT, 'a', 'z', '16777216.0'::FLOAT, '16777217.0'::DOUBLE, 16777217, 16777217, '16777215.0'::FLOAT),
    (2, 11, 11, 11, 11, '11.0'::DOUBLE, '11.0'::DOUBLE, '11.0'::FLOAT, '11.0'::FLOAT, 'bb', 'bb', '16777216.0'::FLOAT, '16777216.0'::DOUBLE, 16777216, 16777216, '16777216.0'::FLOAT),
    (3, 13, 7, 13, 7, '13.0'::DOUBLE, '7.0'::DOUBLE, '13.0'::FLOAT, '7.0'::FLOAT, 'ccc', 'aa', '16777216.0'::FLOAT, '16777215.0'::DOUBLE, 16777215, 16777215, '16777216.0'::FLOAT),
    (4, 17, 23, 17, 23, '17.0'::DOUBLE, '23.0'::DOUBLE, '17.0'::FLOAT, '23.0'::FLOAT, 'dd', 'dd', '-0.0'::FLOAT, '0.0'::DOUBLE, 0, 0, '0.0'::FLOAT),
    (5, 19, 17, 19, 17, '19.0'::DOUBLE, '17.0'::DOUBLE, '19.0'::FLOAT, '17.0'::FLOAT, 'e', 'q', '3.0'::FLOAT, '3.5'::DOUBLE, 3, 3, '3.5'::FLOAT),
    (6, 23, 19, 23, 19, '23.0'::DOUBLE, '19.0'::DOUBLE, '23.0'::FLOAT, '19.0'::FLOAT, 'ffff', 'ffff', '7.0'::FLOAT, '7.0'::DOUBLE, 7, 7, '7.0'::FLOAT);
