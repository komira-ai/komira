-- A LEFT JOIN of a table registered from memory (lj_customer_mem) with a
-- Parquet table (lj_orders), counted per customer: customer 4 has no order
-- and counts 0, as in DuckDB.
SELECT c.c_id AS c_id, count(o.o_id) AS n FROM lj_customer_mem AS c LEFT JOIN lj_orders AS o ON c.c_id = o.o_cust GROUP BY c.c_id ORDER BY c_id ASC NULLS LAST
