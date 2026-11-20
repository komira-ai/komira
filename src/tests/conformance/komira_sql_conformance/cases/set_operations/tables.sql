-- Two-column arms for set operations (k BIGINT, g VARCHAR): ta and tb share one row and
-- each holds NULL keys, so UNION/INTERSECT/EXCEPT must treat NULL as equal to NULL; te is
-- empty, tn is all NULL, tv has a VARCHAR key to be widened against ta's BIGINT.
-- ab, ae, an and abn hold the concatenation of the named arms (the multi-arm scans).
CREATE TABLE ta (k BIGINT, g VARCHAR);
INSERT INTO ta VALUES
    (1, 'x'),
    (2, 'y'),
    (3, 'x'),
    (NULL, NULL);
CREATE TABLE tb (k BIGINT, g VARCHAR);
INSERT INTO tb VALUES
    (3, 'x'),
    (4, 'z'),
    (NULL, NULL),
    (NULL, 'w');
CREATE TABLE te (k BIGINT, g VARCHAR);
CREATE TABLE tn (k BIGINT, g VARCHAR);
INSERT INTO tn VALUES
    (NULL, NULL),
    (NULL, NULL),
    (NULL, NULL);
CREATE TABLE tv (k VARCHAR, g VARCHAR);
INSERT INTO tv VALUES
    ('3', 'x'),
    ('abc', 'q');
CREATE TABLE ab (k BIGINT, g VARCHAR);
INSERT INTO ab SELECT k, g FROM ta;
INSERT INTO ab SELECT k, g FROM tb;
CREATE TABLE ae (k BIGINT, g VARCHAR);
INSERT INTO ae SELECT k, g FROM ta;
INSERT INTO ae SELECT k, g FROM te;
CREATE TABLE an (k BIGINT, g VARCHAR);
INSERT INTO an SELECT k, g FROM ta;
INSERT INTO an SELECT k, g FROM tn;
CREATE TABLE abn (k BIGINT, g VARCHAR);
INSERT INTO abn SELECT k, g FROM ta;
INSERT INTO abn SELECT k, g FROM tb;
INSERT INTO abn SELECT k, g FROM tn;
