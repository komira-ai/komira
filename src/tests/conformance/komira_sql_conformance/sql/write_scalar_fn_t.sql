-- The scalar_fn corpus's table T as Parquet, for the function coverage test to
-- register and run each case over.
COPY (SELECT * FROM T ORDER BY k) TO 'scalar_fn_t.parquet' (FORMAT parquet);
