"""mutate: operator mutants of a Mojo package's sources, and their score
(tools/build/coverage/README.md, "Mutation score").

- `lex`: the tokens of a source, enough to find operators outside strings
  and comments;
- `gen`: the mutants of one file, and the markers that suppress some;
- `sample`: the deterministic sample a run builds, and the list file;
- `score`: each mutant's verdict from its build steps, and the report;
- `cli`: the `mutate` command line.
"""
