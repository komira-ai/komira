-- A profit expression (price less a percent discount less supply cost
-- times quantity, in cents) through a two-key join and a second join,
-- grouped by year. Catches the compound expression summed wrong, and a
-- two-key join matched on one key (partsupp (1, 20) must match nothing).
SELECT s.s_year AS s_year, sum(li.li_price * (100 - li.li_pct) - ps.ps_cost * li.li_quantity * 100) AS profit_cents FROM profit_lineitem AS li JOIN profit_partsupp AS ps ON li.li_part = ps.ps_part AND li.li_supp = ps.ps_supp JOIN profit_supplier AS s ON li.li_supp = s.s_supp GROUP BY s.s_year ORDER BY s_year ASC NULLS LAST
