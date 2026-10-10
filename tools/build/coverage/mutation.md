# Mutation score

Part of the coverage tooling ([README.md](README.md)).

The branch-strength measure where branch coverage is not enforced: a
mutant is the package with one small fault planted, and a test suite that
cannot tell the two apart (every welded test still passes) leaves a
decision untested. Report-only: nothing runs it by default, and no build
action passes its mutants file to covcheck.

```sh
./buck2 build -c komira.mutation=true '//src/komira_retry:komira_retry[mutation]'
```

`-c komira.mutation=true` gives every `mojo_library` on linux-x86_64 the
sub-target `[mutation]` (`tools/build/mojo/mutation.bzl`), whose outputs
are `mut/mutants.tsv`, the mutants file ([README.md](README.md#the-mutants-file)) (paths from the repository
root, `col <c>: <change>; <why>` as the description), and `mut/summary.md`:
the score, every survivor as `<file>:<line>:<col> <operator>: <change>`,
timeouts and errors with their reason, the compiler's last lines for each
`error`, and the mutants a marker suppressed. Nothing
depends on it, so only building it by name runs anything. With the switch
off the `mutation_*` attributes are unset (their defaults) and no action
changes; with it on, no other action of the library changes either.

| setting (`-c komira.<name>=`) | default | what |
|---|---|---|
| `mutation` | `false` | the switch |
| `mutation_sample` | `30` | mutants built per library; `0` is every one |
| `mutation_seed` | `0` | which ones (below) |
| `mutation_compile_timeout_secs` | `900` | the limit of each compile of a mutant (its library, each test) |
| `mutation_run_timeout_secs` | `120` | the limit of each test run of a mutant |

## The mutants

`mutate` (`mutate/`, a `mojo_library` with its tests welded, and
`:mutate_bin`) lexes each hand-written source of the library (`srcs` that
are source files; generated ones are compiled, not mutated): identifiers,
numbers, strings (`"..."`, `'...'`, triple-quoted, prefixed such as
`r"..."`, and backtick-quoted MLIR text), comments, operators by longest
match, and logical line ends (none inside brackets or after a backslash).
Only tokens outside strings and comments are mutated, one change per
mutant, named `<file>:<line>:<col>:<operator>` (line and column, in bytes,
of the changed text):

| operator | change |
|---|---|
| `cmp_negate` | `==` `!=` `<` `<=` `>` `>=` to its negation: `!=` `==` `>=` `>` `<=` `<` |
| `arith_swap` | a binary `+` to `-` and back (the token before it is an operand: a name that is not a keyword, a number, a string, a closing bracket), `+=` to `-=` and back |
| `bool_swap` | `and` to `or` and back |
| `not_delete` | `not` deleted |
| `const_inc`, `const_dec` | a decimal integer literal of at most 18 digits (no `_`, `.`, exponent or base prefix) plus one; minus one (not for `0`) |
| `raise_delete` | a `raise` statement, to its end (over lines while brackets are open, or to a `;`), replaced by `pass` |
| `return_early` | `return` inserted before the first statement (after a docstring) of a `def` returning nothing (no `->`, or `-> None`) |
| `return_true`, `return_false` | `return True`; `return False` inserted likewise in a `def` returning `Bool` |

No early return is made for a `def` taking `out` (a constructor), one with
a one-line body, or one whose first statement is `pass`, `...` or already
the inserted statement: those mutants are equivalent or cannot compile.
Shifts, `->`, a unary sign, floats, exponents and hex literals are left
alone.

**Equivalent mutants.** A mutant no test can kill because it does not
change behaviour is suppressed in the source by an end-of-line comment on
the line it is reported at: `# mutation: equivalent <operator>[,<operator>...] <reason>`
suppresses those operators on that line, and `# cov: unreachable <reason>`
(see Exemptions) every mutant of the line. Any other comment starting
`# mutation:` (a bare `# mutation: equivalent`, a misspelt kind), a marker
with no reason, or one naming an unknown operator, fails the list, naming
`<file>:<line>`. Suppressed mutants are listed
in the list file and in the summary under "Suppressed by a marker (need
approval)", as exemptions are. A mutant that does not compile is not
equivalent: it is `error`, outside the score's numerator.

**The sample.** Of the library's mutants, the `mutation_sample` whose
FNV-1a 64 hash of `<seed>` LF `<id>` is smallest are built, in source
order. A mutant's place in the sample depends on its id, the seed and the
others' hashes only, so an edit elsewhere moves few mutants in or out, and
a larger sample with the same seed holds the smaller one. A nightly run
varies the seed (the date, say) to cover a package over time.

## One mutant's build

For each sampled mutant, under
`mut/m/<file>/<line>_<col>_<operator>/` (a path named by the id, so a
mutant's actions are the same actions whatever else was sampled, and
the cache keeps them while the library's sources, deps and tests are
unchanged):

1. `mutation_apply`: `mutate apply` writes the file with the change;
2. `mutation_precompile`: the library's sources with that file in place,
   precompiled against its deps;
3. per `test_srcs` entry, `mutation_build_test`: the test built against
   that package exactly as its gated build is (optimization level,
   defines, test deps, link), and `mutation_run_test`: its run through the
   gate's runner exactly as the gate runs it: the test's data, environment
   and memory cap (none when the gate's run has none).

**The baseline.** The library unchanged goes through the same steps under
`mut/baseline/` (a no-op `mutate apply` of its first source, the
precompile, every test's build and run). `mutate score` refuses (the build
fails, naming the step and its output) unless every baseline step is
`ok`: a harness that fails every test, such as a wrong runner argument or
environment, would otherwise count every mutant killed and score 100%.

Each step runs through `mutate/mut_step.sh`, in a session of its own. It
records `ok`, `fail <status>`, `timeout <secs>` (the step was still running
at its limit; its whole process group was killed) or `skipped` (a step it
waits for was not `ok`), then the last lines of the output, and exits 0:
that is the mutant's result, cached as any action's output. One exception:
a compile that exits with a status of the compile wrapper's own
(`mojo_wrapper.sh`: 2, 3 and 4, its refusals; 124, the watchdog; 129, 130
and 143, a signal) fails the action. That is the machine failing, not the
mutant, so it is never cached as a result: the build fails and a rerun
retries it. A file the step writes that is no output (the runner's PASS
marker, the log) goes to buck2's scratch directory for the action.
`mut_step_cases` (`mut_step_cases.sh`) holds each of these outcomes. A README's examples are not run against
a mutant. `mutation_score` (`mutate score`) reads every status and decides,
first rule that holds:

| status | when |
|---|---|
| `error` | the precompile is not `ok`: the mutated library does not compile |
| `killed` | a test run fails (an assertion, a crash, the memory cap) |
| `timeout` | a test run timed out |
| `error` | a test does not compile against it (or its compile timed out) |
| `survived` | every test compiled and passed |

A test that does not compile is not a kill: `mojo precompile` does not
instantiate generic code, so a mutant the compiler rejects is often first
rejected when a test is built against it, and that is the compiler's
verdict on a stillborn mutant, not a test's.

The score is covcheck's: `killed * 10000 / total` basis points over every
sampled mutant; the summary also gives the detected share
(killed or timeout) and the score over the mutants that compiled.
