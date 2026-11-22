-- The table of the directory test: m(id, g, v, s), 30 rows, 3 files of ten rows
-- (id 1..10, 11..20, 21..30). g groups the rows across the files, v is a
-- DECIMAL(18, 2) with a fractional part, s a short string.
CREATE TABLE m AS
SELECT id::BIGINT AS id,
       (id % 4)::BIGINT AS g,
       CAST(CAST(id * 137 % 1000 AS VARCHAR) || '.' || lpad(CAST(id * 7 % 100 AS VARCHAR), 2, '0') AS DECIMAL(18, 2)) AS v,
       's' || CAST(id % 5 AS VARCHAR) AS s
FROM range(1, 31) AS r(id);
