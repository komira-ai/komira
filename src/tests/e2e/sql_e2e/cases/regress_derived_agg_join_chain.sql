-- A profit expression (price less discount less supply cost) through a
-- two-key join and a second join, grouped by year. Catches the compound
-- expression summed wrong, and a two-key join matched on one key (partsupp
-- (1, 20) must match nothing).
SELECT s.s_year AS s_year, sum(li.li_price - li.li_price * li.li_discount - ps.ps_cost * li.li_quantity) AS profit FROM profit_lineitem AS li JOIN profit_partsupp AS ps ON li.li_part = ps.ps_part AND li.li_supp = ps.ps_supp JOIN profit_supplier AS s ON li.li_supp = s.s_supp GROUP BY s.s_year ORDER BY s_year ASC NULLS LAST
