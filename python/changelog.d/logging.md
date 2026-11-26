- **Logging.** komira logs to the `logging` logger `"komira"`, which has a `NullHandler`: at `DEBUG`
  the library it loaded and each answered query's plan segments, at `INFO` a query stopped by an
  exception. It logs no query text.
