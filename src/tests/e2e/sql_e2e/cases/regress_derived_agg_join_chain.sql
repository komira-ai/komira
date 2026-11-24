-- A profit expression (price less discount less supply cost) through a
-- two-key join and a second join, grouped by year. Catches the compound
-- expression summed wrong, and a two-key join matched on one key (partsupp
-- (1, 20) must match nothing).
SELECT s.s_year AS s_year, sum(li.l_extendedprice - li.l_extendedprice * li.l_discount - ps.ps_supplycost * li.l_quantity) AS profit FROM profit_lineitem AS li JOIN profit_partsupp AS ps ON li.l_partkey = ps.ps_partkey AND li.l_suppkey = ps.ps_suppkey JOIN profit_supplier AS s ON li.l_suppkey = s.s_suppkey GROUP BY s.s_year ORDER BY s_year ASC NULLS LAST
