- **Where a syntax error is.** A statement the engine cannot parse raises `ParseError` from `sql`
  with a message that ends with where it stopped parsing, `at line <L>, column <C>`:
  `parse: SQL syntax error: expected keyword 'by' at line 1, column 42`.
