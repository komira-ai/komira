# Program sources in the coverage census

Status: decided and built. Reference: [tools/build/coverage/README.md](../../tools/build/coverage/README.md),
"Program sources".

## What problem does this solve?

A mopm package that ships a program names its source in `mopm.toml`:
`[targets] bins = [{ name = "x", path = "bins/x.mojo" }]`. The program's `main` runs only inside the built
program. The census instruments test binaries, not programs, so the file's lines were counted as uncovered
(`UnmeasuredFile`) whatever the tests did. A package with a program could not hold its line metric even when a
test ran the program on every build.

## The decisions

1. **Which files are programs comes from the manifest, read strictly.** The manifest is the package's own statement
   of its programs; a directory convention (`bins/`) is not. covcheck reads the statements of the manifest with its
   own scanner (`covcheck/manifest.mojo`) and refuses, with the manifest and line, every shape it does not read:
   an unclosed or mismatched value, a malformed table name, a `bins` that is not an array of `{ name, path }`
   entries, an entry whose path is not a relative `.mojo` file of the same package, two entries naming one file or
   sharing a name, an entry naming a test source. A misread manifest could otherwise take source out of the numbers
   silently, so an odd shape stops the run instead.
2. **A program is left out of the numbers, as a generated source is.** Its line records, branch records and mutants
   are dropped, it is no `UnmeasuredFile`, and its package is still measured, so the package's other sources still
   count. The floor does not change; this says what it measures.
3. **Leaving a program out is honest only if a test runs it: `UnrunProgram`.** The evidence is the build graph,
   not a reading of source text: a test target of the program's own package depends on the program target
   (typically `data = {"bin": ":prog[runnable]"}`). The census runs one `buck2 uquery`, the union of one selection
   per measured package with a manifest, and passes buck2's JSON of the selected targets' `main` and `srcs` to
   covcheck. covcheck takes each target's entry point (its `main`, else its one source), so a file a program
   target merely lists is no evidence, and a test in another package is none either. A failing query fails the
   census; it never reads as "no program runs".
4. **covcheck stays pure.** It reads manifests, reports and the JSON as data; the query is the census script's one
   build-graph step, next to the queries it already runs for the library lists.

## Report and gate

The report (`covcheck report`, the pull request's coverage check) gets the evidence. The build gate of a
`mojo_library` (`tools/build/mojo/coverage.bzl`) does not: no `mojo_library` package declares `bins`, and the
packages that ship programs are built with buildrules' `mojo_package`, whose numbers come from the report. A
`bins` entry in a `mojo_library` is therefore always `UnrunProgram` at its gate until the gate is given the same
query; that change belongs with the first such library.

## Options weighed

- **Excluding `bins/` by path.** Rejected: a file there that no manifest names would leave the numbers without a
  statement that it is a program, and without a test that runs it.
- **Exempting the lines with markers.** Rejected: the exemption list is for lines a test cannot reach for a reason
  a reviewer approves; a program's `main` is reachable, by running the program.
- **Searching test sources for the program's name.** Rejected: text is not evidence that the build runs the
  program; the dependency in the build graph is.
- **A new BXL script for the evidence.** Not needed: `deps`, `kind` and `attrfilter` over the unconfigured graph
  answer the question, and the census already drives `uquery`.
