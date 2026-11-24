-- Orders per customer through a LEFT JOIN with a residual filter, then
-- customers per order count. Catches the count-0 bin lost (customer 4 has
-- no order, customer 6 only one the filter removes).
SELECT c_count, count(*) AS custdist FROM (SELECT c.c_id AS c_id, count(o.o_id) AS c_count FROM lj_customer AS c LEFT JOIN lj_orders AS o ON c.c_id = o.o_cust AND o.o_comment NOT LIKE '%special%' GROUP BY c.c_id) AS co GROUP BY c_count ORDER BY custdist DESC NULLS LAST, c_count DESC NULLS LAST
