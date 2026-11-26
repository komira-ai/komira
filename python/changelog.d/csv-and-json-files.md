- **CSV and JSON files.** `Session.register_csv(name, path, *, delimiter=",", header=True,
  all_varchar=False)` and `Session.register_json(name, path)` register a CSV file and a
  newline-delimited JSON file as a table for `Session.sql`, with the column names and types the
  engine infers when the call is made: the table `read_csv` or `read_json` makes of the same file.
  A relative path is resolved against the working directory and `~` is expanded. A missing, empty or
  unreadable file, or a name the session already has, raises `KomiraError` with the engine's message.
  They need libkomira ABI 1.5.
