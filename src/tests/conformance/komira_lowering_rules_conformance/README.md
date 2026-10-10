# komira_lowering_rules_conformance

Test-only. Checks `komira_lowering_rules`' payload-narrowing rule,
`derive_payload_narrow`, against the optimizer rule it replaces,
`komira_optimizer`'s payload-narrowing pass, on a fixture set.

```text
fixtures.mojo                the builders and fixtures of komira_optimizer's
                             payload-narrowing parity table, copied verbatim
extra_fixtures.mojo          the cases this package adds, and `build(name)`
render.mojo                  a case's footer list (each scan's statistics, in
                             scan pre-order) and the table's row rendering
golden.mojo                  the reader of the golden file
golden/payload_narrow.txt    one row per case, `<case> => scan#0: ... | ...`:
                             the optimizer's 83-row table verbatim, then the
                             added cases
tests/test_payload_narrow_parity.mojo
```

The welded test builds the fixture each golden row names, runs both rules on
it, and compares each rendering with the row, reporting every mismatch. On a
mismatch it prints both rules' rows for the whole file. It also pins the row
count and the order of the added cases, and checks that the rows hold
results of every width and empty ones.

To add a case, add its builder to `_extra_fixture` and its name to
`extra_names` in `extra_fixtures.mojo`, append its row to the golden file,
and build the package. A wrong row fails the test, which prints the row each
rule gives. Once the optimizer rule is deleted, the golden file is the only
expectation.
