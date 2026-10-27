-- `join_left` (40 rows) and `join_right` (30 rows): a join pair. Key k holds
-- NULL, 1 twice in the first rows, and a key only one side holds (9 on the
-- left, 10 on the right); the string key k2 holds '' and NULL.
CREATE TABLE join_left AS
SELECT
    CAST(i AS BIGINT) AS id,
    CASE WHEN i < 4 THEN CAST([NULL, 9, 1, 1] AS BIGINT[])[i + 1]
         WHEN draw(i, 201) % 100 < 15 THEN NULL ELSE CAST(draw(i, 202) % 10 AS BIGINT) END AS k,
    CASE WHEN i < 3 THEN ['', NULL, 'x'][i + 1]
         WHEN draw(i, 203) % 100 < 15 THEN NULL ELSE ['x', 'y', ''][CAST(draw(i, 204) % 3 AS BIGINT) + 1] END AS k2,
    CASE WHEN i < 1 THEN NULL
         WHEN draw(i, 205) % 10 < 2 THEN NULL ELSE CAST(draw(i, 206) % 201 AS INTEGER) - 100 END AS lv
FROM range(40) AS r(i);

CREATE TABLE join_right AS
SELECT
    CAST(i AS BIGINT) AS id,
    CASE WHEN i < 4 THEN CAST([NULL, 10, 1, 1] AS BIGINT[])[i + 1]
         WHEN draw(i, 301) % 100 < 15 THEN NULL
         ELSE CAST([0, 1, 2, 3, 4, 5, 6, 7, 8, 10] AS BIGINT[])[CAST(draw(i, 302) % 10 AS BIGINT) + 1] END AS k,
    CASE WHEN i < 3 THEN ['', NULL, 'x'][i + 1]
         WHEN draw(i, 303) % 100 < 15 THEN NULL ELSE ['x', 'y', ''][CAST(draw(i, 304) % 3 AS BIGINT) + 1] END AS k2,
    CASE WHEN i < 2 THEN [NULL, ''][i + 1]
         WHEN draw(i, 305) % 10 < 2 THEN NULL ELSE draw_word(i, 306) END AS rv
FROM range(30) AS r(i);
