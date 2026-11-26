-- The scalar_fn corpus's tables T and E as Parquet, for the function
-- coverage test to register and run each case over.
COPY (SELECT * FROM T ORDER BY k) TO 'scalar_fn_t.parquet' (FORMAT parquet);
COPY (SELECT * FROM E ORDER BY k) TO 'scalar_fn_e.parquet' (FORMAT parquet);
