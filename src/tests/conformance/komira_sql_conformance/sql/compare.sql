-- first_difference(got, want): NULL when the two texts are equal byte for
-- byte, else where they first differ, as 'line <n>: got <line>, want <line>'
-- (a line is text between LF bytes; 'no line' past the end of one text). The
-- comparison is of the whole texts, so a difference the line split cannot
-- show (a trailing LF) is still reported, at the line past the shorter end.
CREATE MACRO corpus_line(l, n) AS coalesce('"' || l[n] || '"', 'no line');
CREATE MACRO corpus_lines(t) AS string_split(t, chr(10));
CREATE MACRO corpus_first_line(gl, wl) AS
    list_filter(generate_series(1, greatest(len(gl), len(wl))), lambda i: gl[i] IS DISTINCT FROM wl[i])[1];
CREATE MACRO corpus_report(gl, wl, n) AS
    'line ' || n || ': got ' || corpus_line(gl, n) || ', want ' || corpus_line(wl, n);
CREATE MACRO first_difference(got, want) AS CASE
    WHEN got IS NOT DISTINCT FROM want THEN NULL
    ELSE corpus_report(corpus_lines(coalesce(got, '')), corpus_lines(coalesce(want, '')),
        corpus_first_line(corpus_lines(coalesce(got, '')), corpus_lines(coalesce(want, ''))))
    END;
