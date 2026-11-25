-- IN over a subquery that holds supplier 1 twice: suppliers 1, 2, 3, each
-- once. Catches a duplicate in the subquery repeating an outer row.
SELECT s_suppkey FROM in_supplier WHERE s_suppkey IN (SELECT ps_suppkey FROM in_partsupp) ORDER BY s_suppkey ASC NULLS LAST
