-- group_by.tsv: a string key with a NULL group.
COPY (
SELECT k, count(*) AS c, sum(id) AS sid, max(f) AS fmax FROM read_json('rows.jsonl') GROUP BY k
) TO 'group_by.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
