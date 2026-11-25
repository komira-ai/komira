-- Orders per customer through a LEFT JOIN with a residual filter, then
-- customers per order count. Catches the count-0 bin lost (customer 4 has
-- no order, customer 6 only one the filter removes).
SELECT n_orders, count(*) AS n_customers FROM (SELECT c.c_id AS c_id, count(o.o_id) AS n_orders FROM lj_customer AS c LEFT JOIN lj_orders AS o ON c.c_id = o.o_cust AND o.o_comment NOT LIKE '%special%' GROUP BY c.c_id) AS co GROUP BY n_orders ORDER BY n_customers DESC NULLS LAST, n_orders DESC NULLS LAST
