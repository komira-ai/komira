<!--
A pull request that DECLARES a library in release/artifacts.textproto: a new
entry above the metapackage, and its manifest in the metapackage's args. Open
it with this template (`?template=declare.md` on the compare page, or
`gh pr create --template declare.md`); docs/releases.md, "Declaring a
library", says why.

A name and version published to the channel are permanent in practice. A
library that builds and passes its tests can still stay undeclared: the
release approver approves a declaration only when they trust its testing plan
below. Fill every section for every library the change declares. "None" is an
answer only when you say why; an empty or deleted section is a request to
wait.
-->

## What this declares

| library | new names | README examples (the validation that runs them) |
|---|---|---|
| `komira_<name>` | `komira_<name>` | `src/komira_<name>/README.md`: N examples |

Stacking: Not stacked | Stacked on #N (retargeted to `main` before it is merged)

## Testing plan

One block per library. The approver reads this before the name becomes
permanent: write it for a stranger who will depend on the library without
reading its source.

### `komira_<name>`

**What is tested.** One row per file of the library's `test_srcs` (the build
runs them; a test not named there never runs: `tools/build/mojo/README.md`,
"Libraries and the `test_srcs` gate").

| test | what it proves | the defect it would catch |
|---|---|---|
| `tests/test_<x>.mojo` | | |

**Mutants.** Each defect you planted, the command, and the result line. At
least one mutant per public entry point; the build must go red on each.

| mutant (file, the change) | command | result line |
|---|---|---|
| | `./buck2 build //src/komira_<name>:komira_<name>` | `BUILD FAILED` (`test_<x>`: ...) |

**Surviving mutants.** Every planted defect that NO test caught, why it
survived, and whether this pull request accepts it (and why) or adds the test
that kills it. "None survived" lists how many you planted.

**Deadlines.** Every operation that can block: I/O, a socket, a child
process, a lock, a wait on another task. For each: its deadline or timeout,
who sets it, and the test that proves it fires. An operation with no deadline
is listed here as having none, with what a caller sees when it hangs.

| operation | deadline (who sets it) | the test that proves it fires |
|---|---|---|
| | | |

**Untested composition.** What a user will combine this library with that no
test exercises: other libraries, concurrent callers, platforms other than
linux-64, inputs larger than the tests use, failure of a dependency. Say
which of these a user is most likely to hit first.

## Proof

The exact commands and their summary lines (`Commands: N (cached: N, remote:
N, local: 0)` and `BUILD SUCCEEDED`/`BUILD FAILED`), including each mutant's
red build and the green build after it was removed.

```text
```

## Approver's checklist

- [ ] Every declared library has all four parts above, filled.
- [ ] Each surviving mutant is accepted with a reason I agree with, or killed by a test in this pull request.
- [ ] Every blocking operation has a deadline, or its absence is one I accept for a published name.
- [ ] The untested composition is one I am willing to ship under this name.
