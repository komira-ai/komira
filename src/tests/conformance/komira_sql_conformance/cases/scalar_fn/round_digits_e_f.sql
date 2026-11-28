-- order: rows
SELECT k, round(f, 0) AS r0, round(f, 1) AS r1, round(f, -1) AS rm1, round(f, 400) AS r400, round(f, -400) AS rm400 FROM E
