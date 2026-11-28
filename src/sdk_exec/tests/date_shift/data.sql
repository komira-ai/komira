-- The table of test_run_sql_date_shift, written by DuckDB: orders(id, order_date,
-- ship_date), two DATE columns with a NULL in each. The dates cover the month-end
-- clamp (31 Jan, 31 Mar, 29 Feb), a non-leap 31 Jan, a date before 1970 and a
-- ship date exactly seven days after its order date.
COPY (
    SELECT * FROM (VALUES
        (1, DATE '2024-01-31', DATE '2024-02-10'),
        (2, DATE '2023-01-31', DATE '2023-01-31'),
        (3, DATE '2024-02-29', DATE '2024-03-10'),
        (4, DATE '2024-03-31', DATE '2024-03-31'),
        (5, NULL, DATE '2024-01-01'),
        (6, DATE '2023-12-25', NULL),
        (7, DATE '1969-12-31', DATE '1970-01-02'),
        (8, DATE '2024-02-10', DATE '2024-02-17'),
        (9, DATE '2021-05-01', DATE '2021-05-20')
    ) t(id, order_date, ship_date)
) TO 'orders.parquet' (FORMAT parquet);
