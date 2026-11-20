-- Table T with 13 rows: k (row number), v (k plus one), tag (never NULL) and note.
-- note repeats a pattern of an empty string, NULLs and short words, so a case can tell
-- an empty string from a NULL; the row count puts NULLs in a partial trailing group.
CREATE TABLE T (k INTEGER, v INTEGER, tag VARCHAR, note VARCHAR);
INSERT INTO T VALUES
    (0, 1, 'y1', ''),
    (1, 2, 'y3', NULL),
    (2, 3, 'y2', 'zzz'),
    (3, 4, 'y3', 'zzz'),
    (4, 5, 'y3', NULL),
    (5, 6, 'y1', 'bbb'),
    (6, 7, 'y2', NULL),
    (7, 8, 'y3', 'zab'),
    (8, 9, 'y1', ''),
    (9, 10, 'y3', NULL),
    (10, 11, 'y2', 'zzz'),
    (11, 12, 'y3', 'zzz'),
    (12, 13, 'y3', NULL);
