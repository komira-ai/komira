# komira_lowering_rules_conformance

Test-only. Checks `komira_lowering_rules`' payload-narrowing rule,
`derive_payload_narrow`, against the optimizer rule it replaces,
`komira_optimizer`'s payload-narrowing pass, on a fixture set.

```text
fixtures.mojo                the fixtures: plans whose scans carry statistics,
                             one input moved at a time from a join that narrows;
                             each scan's statistics are also its footer entry
golden.mojo                  the reader of the golden file
golden/payload_narrow.tsv    one line per fixture: <case> TAB <specs>, one [...]
                             per scan in scan pre-order
tests/test_payload_narrow_parity.mojo
```

The welded test runs both rules on every fixture and compares each with the
fixture's golden line, reporting every mismatch. On a mismatch it prints the
optimizer rule's results for the whole set as golden lines. It also checks
that the golden file names exactly the fixtures and holds results of every
width and empty ones.

To add a fixture, add it to a `_*_cases` function in `fixtures.mojo`, add its
golden line, and build the package. A wrong golden line fails the test, which
prints the line the optimizer rule gives. Once the optimizer rule is deleted,
the golden file is the only expectation.
