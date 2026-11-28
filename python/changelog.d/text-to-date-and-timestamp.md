- **Parsing text into dates.** SQL gains `CAST(text AS DATE)`, `CAST(text AS TIMESTAMP)`,
  `TRY_CAST(text AS DATE | TIMESTAMP)` (NULL for text that does not parse), `strptime(text, format)`
  and `try_strptime(text, format)`, which return a `TIMESTAMP` in microseconds as DuckDB does, and
  `s.astype("date32")` / `df.astype({"col": "date32"})` on a string column parses the text as
  `CAST(... AS DATE)` does. The format must be a constant string. Refused by name: the directives
  `%z`, `%Z`, `%n` and the week-based `%G %V %u %U %W %w`, and a list of formats.
  `komira.to_datetime()` is still refused.
