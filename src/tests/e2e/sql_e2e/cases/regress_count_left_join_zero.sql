-- count over a LEFT JOIN per customer: customer 4 has no order. Catches the
-- customer with no order dropped or counted 1 (its NULL-padded row counted).
SELECT c.c_id AS c_id, count(o.o_id) AS n FROM lj_customer AS c LEFT JOIN lj_orders AS o ON c.c_id = o.o_cust GROUP BY c.c_id ORDER BY c_id ASC NULLS LAST
