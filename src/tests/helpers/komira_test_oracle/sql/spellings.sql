-- How the pinned DuckDB spells each value in an expected TSV (COPY ... TO
-- '<name>.tsv' (FORMAT csv, DELIMITER '\t', HEADER true)), one row per
-- spelling, for test_duckdb_spellings: the Mojo reader is held to the bytes
-- DuckDB writes, not to a transcription of them. `what` names the row.
COPY (
    SELECT * FROM (VALUES
        (1, 'zeros', CAST(0 AS BIGINT), CAST(0 AS UBIGINT), CAST('-0.0' AS DOUBLE), CAST('-0.0' AS FLOAT), CAST(0 AS DECIMAL(9,2)), CAST('' AS VARCHAR), false),
        (2, 'nulls', CAST(NULL AS BIGINT), CAST(NULL AS UBIGINT), CAST(NULL AS DOUBLE), CAST(NULL AS FLOAT), CAST(NULL AS DECIMAL(9,2)), CAST(NULL AS VARCHAR), CAST(NULL AS BOOLEAN)),
        (3, 'extremes', CAST(-9223372036854775808 AS BIGINT), CAST(18446744073709551615 AS UBIGINT), CAST('1.7976931348623157e308' AS DOUBLE), CAST('3.4028235e38' AS FLOAT), CAST('-9999999.99' AS DECIMAL(9,2)), CAST('tab' || chr(9) || 'nl' || chr(10) || 'cr' || chr(13) || 'end' AS VARCHAR), true),
        (4, 'nan', CAST(-1 AS BIGINT), CAST(1 AS UBIGINT), CAST('nan' AS DOUBLE), CAST('nan' AS FLOAT), CAST('0.01' AS DECIMAL(9,2)), CAST('say "hi"' AS VARCHAR), true),
        (5, 'inf', CAST(9223372036854775807 AS BIGINT), CAST(2 AS UBIGINT), CAST('inf' AS DOUBLE), CAST('-inf' AS FLOAT), CAST('-0.01' AS DECIMAL(9,2)), CAST('\N' AS VARCHAR), false),
        (6, 'least', CAST(7 AS BIGINT), CAST(3 AS UBIGINT), CAST('5e-324' AS DOUBLE), CAST('1e-45' AS FLOAT), CAST('12.30' AS DECIMAL(9,2)), CAST('back\slash é 世界 😀' AS VARCHAR), true),
        (7, 'tenth', CAST(8 AS BIGINT), CAST(4 AS UBIGINT), CAST('0.1' AS DOUBLE), CAST('0.1' AS FLOAT), CAST('1' AS DECIMAL(9,2)), CAST('NULL' AS VARCHAR), true),
        (8, 'large', CAST(9 AS BIGINT), CAST(5 AS UBIGINT), CAST('1e300' AS DOUBLE), CAST('1e30' AS FLOAT), CAST('100' AS DECIMAL(9,2)), CAST(' lead and trail ' AS VARCHAR), false),
        (9, 'small', CAST(10 AS BIGINT), CAST(6 AS UBIGINT), CAST('1.5e-7' AS DOUBLE), CAST('-2.5' AS FLOAT), CAST('-1.5' AS DECIMAL(9,2)), CAST('a,b' AS VARCHAR), false),
        (10, 'negnan', CAST(11 AS BIGINT), CAST(7 AS UBIGINT), -CAST('nan' AS DOUBLE), CAST('123456.7' AS FLOAT), CAST('5' AS DECIMAL(9,2)), CAST('"' AS VARCHAR), true)
    ) AS t(id, what, i64, u64, f64, f32, dec, s, b)
    ORDER BY id ASC NULLS LAST
) TO 'spellings.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
