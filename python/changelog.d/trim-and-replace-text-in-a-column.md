- **Trim and replace text in a column.** On the pandas-shaped frame, `s.str.strip()`, `s.str.lstrip()`
  and `s.str.rstrip()` remove whitespace as Python's `str.strip()` does (a tab, a newline, a
  non-breaking space and the other Unicode spaces), or with `to_strip="xy"` any of the characters `x`
  and `y`. In `komira.pl`, `expr.str.strip_chars()`, `strip_chars_start()` and `strip_chars_end()`
  remove the Unicode whitespace or a set of characters, `expr.str.replace(pattern, value)` replaces
  the first match and `expr.str.replace_all(pattern, value)` every match, with `literal=True` for
  the text itself and `$1`, `${1}`, `$0` and `$$` in the value as polars reads them. SQL has
  DuckDB's `trim(s, chars)`, `ltrim(s, chars)` and `rtrim(s, chars)`; `trim(s)` still removes spaces
  only.
