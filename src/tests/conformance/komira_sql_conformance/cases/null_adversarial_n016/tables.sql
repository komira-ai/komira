-- Table T with 16 rows: k (row number), v (k plus one), t (never NULL), s and u.
-- s repeats a pattern of words, NULLs and empty strings; u is all NULL. A case can tell
-- an empty string from a NULL, and the row count varies the trailing partial group.
CREATE TABLE T (k INTEGER, v INTEGER, t VARCHAR, s VARCHAR, u VARCHAR);
INSERT INTO T VALUES
    (0, 1, 'p1', 'zap', CAST(NULL AS VARCHAR)),
    (1, 2, 'p2', NULL, CAST(NULL AS VARCHAR)),
    (2, 3, 'p1', '', CAST(NULL AS VARCHAR)),
    (3, 4, 'p3', 'bz', CAST(NULL AS VARCHAR)),
    (4, 5, 'p2', NULL, CAST(NULL AS VARCHAR)),
    (5, 6, 'p1', 'abz', CAST(NULL AS VARCHAR)),
    (6, 7, 'p3', '', CAST(NULL AS VARCHAR)),
    (7, 8, 'p2', 'z', CAST(NULL AS VARCHAR)),
    (8, 9, 'p1', 'zap', CAST(NULL AS VARCHAR)),
    (9, 10, 'p2', NULL, CAST(NULL AS VARCHAR)),
    (10, 11, 'p1', '', CAST(NULL AS VARCHAR)),
    (11, 12, 'p3', 'bz', CAST(NULL AS VARCHAR)),
    (12, 13, 'p2', NULL, CAST(NULL AS VARCHAR)),
    (13, 14, 'p1', 'abz', CAST(NULL AS VARCHAR)),
    (14, 15, 'p3', '', CAST(NULL AS VARCHAR)),
    (15, 16, 'p2', 'z', CAST(NULL AS VARCHAR));
