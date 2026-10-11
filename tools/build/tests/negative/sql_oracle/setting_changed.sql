-- Changes a setting the rule fixes.
SET threads = 4;
COPY (SELECT 1 AS x) TO 'out.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
