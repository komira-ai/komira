-- compare_check: first_difference (compare.sql) over planted pairs, each
-- against the exact report it must give (NULL for an equal pair). A macro
-- that stops seeing a difference, or reports the wrong line, fails this
-- target with every disagreement listed; its output lists the pairs.
CREATE TABLE planted (name VARCHAR, got VARCHAR, want VARCHAR, report VARCHAR);
INSERT INTO planted VALUES
    ('equal', 'a' || chr(10) || '1' || chr(10), 'a' || chr(10) || '1' || chr(10), NULL),
    ('both empty', '', '', NULL),
    ('changed cell', 'a' || chr(10) || '1' || chr(10), 'a' || chr(10) || '2' || chr(10), 'line 2: got "1", want "2"'),
    ('changed header', 'b' || chr(10) || '1' || chr(10), 'a' || chr(10) || '1' || chr(10), 'line 1: got "b", want "a"'),
    ('missing row', 'a' || chr(10), 'a' || chr(10) || '1' || chr(10), 'line 2: got "", want "1"'),
    ('extra row', 'a' || chr(10) || '1' || chr(10) || '2' || chr(10), 'a' || chr(10) || '1' || chr(10), 'line 3: got "2", want ""'),
    ('missing final LF', 'a' || chr(10) || '1', 'a' || chr(10) || '1' || chr(10), 'line 3: got no line, want ""'),
    ('extra final LF', 'a' || chr(10) || '1' || chr(10) || chr(10), 'a' || chr(10) || '1' || chr(10), 'line 4: got "", want no line'),
    ('CR before LF', 'a' || chr(13) || chr(10), 'a' || chr(10), 'line 1: got "a' || chr(13) || '", want "a"'),
    ('empty cell for NULL', '1' || chr(9) || '' || chr(10), '1' || chr(9) || '""' || chr(10), 'line 1: got "1' || chr(9) || '", want "1' || chr(9) || '"""'),
    ('nothing written', NULL, 'a' || chr(10), 'line 1: got "", want "a"'),
    ('-0.0 for 0.0', 'f' || chr(10) || '-0.0' || chr(10), 'f' || chr(10) || '0.0' || chr(10), 'line 2: got "-0.0", want "0.0"');
CREATE TABLE judged AS
    SELECT name, report, first_difference(got, want) AS got_report FROM planted;
SELECT error('compare_check: ' || string_agg(name || ' reported ' || coalesce(got_report, 'nothing')
        || ', not ' || coalesce(report, 'nothing'), '; ' ORDER BY name ASC NULLS LAST))
FROM judged WHERE got_report IS DISTINCT FROM report HAVING count(*) > 0;
COPY (SELECT name, report FROM judged ORDER BY name ASC NULLS LAST)
TO 'compare_check.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
