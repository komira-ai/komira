-- order: rows
-- pass filter all over a DECIMAL(12,2) column, empty rows
SELECT k, g, v FROM t_empty WHERE k > 2
