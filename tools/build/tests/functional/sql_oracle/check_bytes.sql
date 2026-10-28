-- The first of check's two srcs; check_rows.sql runs after it in the same
-- session and reads the table made here.
CREATE TABLE pairs (what VARCHAR, x VARCHAR, y VARCHAR);
INSERT INTO pairs VALUES
    -- Byte for byte the committed goldens.
    ('golden', 'a/rows.csv', 'golden/rows.csv'),
    ('golden', 'a/expected.tsv', 'golden/expected.tsv'),
    -- Byte for byte the twin's: two executions (the twin's output path,
    -- and so its action key, differs), Parquet included.
    ('twin', 'a/rows.parquet', 'b/rows.parquet'),
    ('twin', 'a/rows.csv', 'b/rows.csv'),
    ('twin', 'a/expected.tsv', 'b/expected.tsv');

CREATE TABLE blobs AS SELECT filename, content FROM read_blob([
    'a/rows.parquet', 'a/rows.csv', 'a/expected.tsv',
    'b/rows.parquet', 'b/rows.csv', 'b/expected.tsv',
    'golden/rows.csv', 'golden/expected.tsv']);

SELECT CASE WHEN count(*) > 0 THEN error('differ: ' || string_agg(p.x || ' vs ' || p.y || ' (' || p.what || ')', ', ' ORDER BY p.x, p.y)) END
FROM pairs p
JOIN blobs bx ON bx.filename = p.x
JOIN blobs by_ ON by_.filename = p.y
WHERE bx.content <> by_.content;

SELECT CASE WHEN count(*) <> 8 THEN error('read ' || count(*) || ' of 8 files') END FROM blobs;
