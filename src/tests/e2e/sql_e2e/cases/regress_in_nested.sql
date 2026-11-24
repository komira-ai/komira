-- IN nested two deep: suppliers with a part that is in part. Catches the
-- inner IN ignored (supplier 2 kept).
SELECT s_suppkey FROM in_supplier WHERE s_suppkey IN (SELECT ps_suppkey FROM in_partsupp WHERE ps_partkey IN (SELECT p_partkey FROM in_part)) ORDER BY s_suppkey ASC NULLS LAST
