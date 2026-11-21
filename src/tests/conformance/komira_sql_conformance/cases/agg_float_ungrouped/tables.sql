-- The inputs of the ungrouped float aggregates: SUM, AVG, MIN, MAX, COUNT and
-- COUNT(*) of a DOUBLE column d and a FLOAT column f. pipeline_exec's
-- tests/test_sink_float_agg_duckdb.mojo builds the same rows, in the order of
-- id, and holds the aggregation sink's answers to these cases by the tolerance
-- rule of its README. Every value is one an exact step gives on both sides: an
-- integer cast and divided once (an IEEE division, rounded to nearest), or a
-- literal whose shortest spelling names that float exactly.
--
-- V: 4096 rows. d is ((i * 7919) % 10007 - 2000) / 7, NULL where i % 8 = 3;
-- f is ((i * 104729) % 1009 - 200) / 3 rounded to FLOAT, NULL where
-- i % 8 = 5. Both mix signs and are well conditioned (the sum of the absolute
-- values is about 1.13 times the absolute value of the sum).
CREATE TABLE V (id BIGINT, d DOUBLE, f FLOAT);
INSERT INTO V
SELECT
    i,
    CASE WHEN i % 8 = 3 THEN NULL
        ELSE (((i * 7919) % 10007) - 2000)::DOUBLE / 7::DOUBLE END,
    CASE WHEN i % 8 = 5 THEN NULL
        ELSE ((((i * 104729) % 1009) - 200)::DOUBLE / 3::DOUBLE)::FLOAT END
FROM range(4096) AS r(i)
ORDER BY i;

-- X: small sets of special values, one set per value of grp, rows in the order
-- of id. 8.98846567431158e307 is 2^1023 and 1.7014118e38 is 2^127.
CREATE TABLE X (grp VARCHAR, id BIGINT, d DOUBLE, f FLOAT);
INSERT INTO X VALUES
    ('nan_mixed', 1, '1.5'::DOUBLE, '1.5'::FLOAT),
    ('nan_mixed', 2, 'nan'::DOUBLE, 'nan'::FLOAT),
    ('nan_mixed', 3, '-2.25'::DOUBLE, '-2.25'::FLOAT),
    ('nan_mixed', 4, NULL, NULL),
    ('nan_mixed', 5, '4.0'::DOUBLE, '4.0'::FLOAT),
    ('nan_first', 1, 'nan'::DOUBLE, 'nan'::FLOAT),
    ('nan_first', 2, '2.0'::DOUBLE, '2.0'::FLOAT),
    ('nan_first', 3, '1.0'::DOUBLE, '1.0'::FLOAT),
    ('nan_only', 1, 'nan'::DOUBLE, 'nan'::FLOAT),
    ('nan_only', 2, NULL, NULL),
    ('nan_only', 3, 'nan'::DOUBLE, 'nan'::FLOAT),
    ('pos_inf', 1, '1.0'::DOUBLE, '1.0'::FLOAT),
    ('pos_inf', 2, 'inf'::DOUBLE, 'inf'::FLOAT),
    ('pos_inf', 3, '2.0'::DOUBLE, '2.0'::FLOAT),
    ('neg_inf', 1, '-inf'::DOUBLE, '-inf'::FLOAT),
    ('neg_inf', 2, '-1.0'::DOUBLE, '-1.0'::FLOAT),
    ('both_inf', 1, 'inf'::DOUBLE, 'inf'::FLOAT),
    ('both_inf', 2, '-inf'::DOUBLE, '-inf'::FLOAT),
    ('both_inf', 3, '3.0'::DOUBLE, '3.0'::FLOAT),
    ('overflow', 1, '8.98846567431158e307'::DOUBLE, '1.7014118e38'::FLOAT),
    ('overflow', 2, '8.98846567431158e307'::DOUBLE, '1.7014118e38'::FLOAT),
    ('overflow', 3, '1.0'::DOUBLE, '1.7014118e38'::FLOAT),
    ('all_null', 1, NULL, NULL),
    ('all_null', 2, NULL, NULL),
    ('all_null', 3, NULL, NULL),
    ('neg_zero', 1, '-0.0'::DOUBLE, '-0.0'::FLOAT),
    ('neg_zero', 2, '-0.0'::DOUBLE, '-0.0'::FLOAT);
