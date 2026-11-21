-- The rows of the Hive test: hl(leaf, id, v, s), 16 rows in four leaf files of
-- four rows. The leaves sit at yr=<year>/tag=<tag>/dt=<date>:
--   leaf 0: yr=2024 tag=red  dt=2024-01-01      leaf 1: yr=2024 tag=blue dt=2024-01-02
--   leaf 2: yr=2025 tag=red  dt=2024-01-01      leaf 3: yr=2025 tag=blue dt=2024-03-05
-- The directory order (yr, tag, dt) differs from the key order a reader
-- answers (dt, tag, yr).
CREATE TABLE hl AS
SELECT ((id - 1) // 4)::INTEGER AS leaf,
       id::BIGINT AS id,
       CAST(CAST(id * 137 % 1000 AS VARCHAR) || '.' || lpad(CAST(id * 7 % 100 AS VARCHAR), 2, '0') AS DECIMAL(18, 2)) AS v,
       chr(97 + (id % 3)::INTEGER) AS s
FROM range(1, 17) AS r(id);
