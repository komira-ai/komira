# The C symbols of the core packages

[`c_symbols.tsv`](c_symbols.tsv) is a hand-kept table: one row per
C symbol of the shim the old core package carried, and the package whose
`cxx_library` now defines it. A Mojo user of `external_call["<symbol>"]`
depends on that owner. The one-definition gate
([`tools/build/one_definition/BUCK`](../build/one_definition/BUCK)) lists the
same symbols, in the same order, in its `exports`, so a library that stops
defining one fails that gate.

The core package is deleted and its modules live in the smaller packages the
split made. The tool that repointed branches still importing it is deleted
too: no open branch predates the delete.
