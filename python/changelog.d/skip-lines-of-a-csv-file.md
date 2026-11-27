- **Skip the lines above a CSV file's header.** `komira.read_csv(path, skiprows=n)` and
  `Session.register_csv(name, path, skip=n)` skip the first `n` lines of the file before the
  header, as SQL's `read_csv(..., skip = n)` does (pandas calls it `skiprows`). The skip is in
  raw lines, so a quote in a skipped line opens no field; `0` and `None` skip nothing. A negative
  count raises `ValueError`, a skip that leaves no line of the file raises `KomiraError` naming
  `CSV_SKIP_PAST_END`, and a list of row numbers or a function for `skiprows` raises
  `UnsupportedOperation`. A skip above `0` needs the library of this release (ABI 1.11); a
  skip of `0` still works with an older one.
