-- order: rows
SELECT k, round(d, 1) AS r1, round(d, 0) AS r0, round(d, -1) AS rm1, round(CAST(d AS FLOAT), 1) AS rf FROM T
