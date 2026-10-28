-- `nulls`: NULL-heavy, 5000 rows (three Parquet row groups), for the three-valued logic, aggregation
-- and join shards. b1 and b2 hold every pair of TRUE, FALSE and NULL in the
-- first nine rows; k groups 1, 2, 3 and NULL; v holds quarters, so every sum
-- is exact in binary floating point; s holds both '' and NULL; all_null is
-- NULL in every row.
CREATE TABLE nulls AS
SELECT
    CAST(i AS BIGINT) AS id,
    CASE WHEN i < 9 THEN CAST([1, 1, 1, 2, 2, 2, NULL, NULL, NULL] AS BIGINT[])[i + 1]
         WHEN draw(i, 1) % 10 < 4 THEN NULL ELSE CAST(draw(i, 2) % 3 AS BIGINT) + 1 END AS k,
    CASE WHEN i < 9 THEN [true, true, true, false, false, false, NULL, NULL, NULL][i + 1]
         ELSE [true, false, NULL][CAST(draw(i, 3) % 3 AS BIGINT) + 1] END AS b1,
    CASE WHEN i < 9 THEN [true, false, NULL, true, false, NULL, true, false, NULL][i + 1]
         ELSE [true, false, NULL][CAST(draw(i, 4) % 3 AS BIGINT) + 1] END AS b2,
    CASE WHEN i < 4 THEN CAST([0, NULL, -5, 5] AS INTEGER[])[i + 1]
         WHEN draw(i, 5) % 10 < 6 THEN NULL ELSE CAST(draw(i, 6) % 11 AS INTEGER) - 5 END AS i32,
    CASE WHEN i < 3 THEN CAST([NULL, 0.25, -0.5] AS DOUBLE[])[i + 1]
         WHEN draw(i, 7) % 2 = 0 THEN NULL ELSE CAST(CAST(draw(i, 8) % 2001 AS INTEGER) - 1000 AS DOUBLE) / 4 END AS v,
    CASE WHEN i < 3 THEN ['', NULL, 'apple'][i + 1]
         WHEN draw(i, 9) % 10 < 4 THEN NULL WHEN draw(i, 10) % 4 = 0 THEN '' ELSE draw_word(i, 11) END AS s,
    CAST(NULL AS BIGINT) AS all_null
FROM range(5000) AS r(i);
