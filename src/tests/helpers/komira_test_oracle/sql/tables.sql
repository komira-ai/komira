-- The tables the oracle cases read: the JSON Lines files the HAND cases of
-- komira_plan_conformance derive their answers from (sort_rows, whose shard
-- is not in the corpus yet, is twins/sort_rows.jsonl here), each with the
-- schema the corpus declares for it (datasets.mojo there): names, types, and
-- id not nullable.
CREATE TABLE bool_pairs (id BIGINT NOT NULL, a BOOLEAN, b BOOLEAN);
INSERT INTO bool_pairs SELECT * FROM read_json('bool_pairs.jsonl', format = 'newline_delimited',
    columns = {'id': 'BIGINT', 'a': 'BOOLEAN', 'b': 'BOOLEAN'});
CREATE TABLE groups (id BIGINT NOT NULL, k BIGINT, v BIGINT);
INSERT INTO groups SELECT * FROM read_json('groups.jsonl', format = 'newline_delimited',
    columns = {'id': 'BIGINT', 'k': 'BIGINT', 'v': 'BIGINT'});
CREATE TABLE ints_nullable (id BIGINT NOT NULL, x BIGINT);
INSERT INTO ints_nullable SELECT * FROM read_json('ints_nullable.jsonl', format = 'newline_delimited',
    columns = {'id': 'BIGINT', 'x': 'BIGINT'});
CREATE TABLE sort_rows (id BIGINT NOT NULL, a BIGINT, b BIGINT, f DOUBLE);
INSERT INTO sort_rows SELECT * FROM read_json('sort_rows.jsonl', format = 'newline_delimited',
    columns = {'id': 'BIGINT', 'a': 'BIGINT', 'b': 'BIGINT', 'f': 'DOUBLE'});
