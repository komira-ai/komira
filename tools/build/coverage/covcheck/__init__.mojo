"""Coverage reports to a GitHub check run, and the per-package build gate
(`covcheck`); see README.md.

`lcov`, `cobertura`: the two report readers, both producing `model.FileCov`;
`branch_lcov`: the reader of branch record files (`--branch-lcov`).
`paths`: from a report path to a repository file, and a file's package.
`diff`: the changed lines of a unified diff. `exempt`: coverage-exemption
markers in sources. `mutants`: the mutation-testing input. `stats`: the
per-package numbers and the findings. `ratchet`: the floors. `analyze`: the
one computation `report` and `gate` share. `annotate`: touched packages,
changed-line coverage, annotations. `summary`: the Markdown. `checkrun`: the
check-run request bodies. `result`: the result JSON (`jsonw`: its writer).
`cli`: the command line. `text`: bytes, numbers, sorting, file I/O.
"""
