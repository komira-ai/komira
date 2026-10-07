# kci_api

The one place that states every number, word and name the kci build and
release tool owns: its exit codes and retry advice, outcome words, stable
error ids, document formats and their schema majors, produced file names, the
release directory layout, the platform table (with conda subdirs and the OCI
`os/arch` spelling), the `--run-id` / `--attempt` / `--context` grammar, full
commit ids and artifact references, the `--only` selector grammar, the verbs
and step kinds, and the result document (`render_result` / `parse_result`).
Every other kci package imports these constants instead of spelling them
itself. The package is pure: no file I/O, no clock, no environment, no
process.

## Examples

A run's outcome maps to one exit number and one retry advice:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_api import EXIT_OK, EXIT_PARTIAL, OUTCOME_NOOP, OUTCOME_PARTIAL, OUTCOME_SUCCEEDED, OUTCOME_FAILED, RETRY_SAFE, RETRY_UNSAFE, default_retry, exit_code_of, worst_outcome

assert_equal(exit_code_of(OUTCOME_NOOP), EXIT_OK)
assert_equal(exit_code_of(OUTCOME_PARTIAL), EXIT_PARTIAL)
assert_equal(default_retry(EXIT_OK), RETRY_SAFE)
assert_equal(default_retry(EXIT_PARTIAL), RETRY_UNSAFE)
assert_equal(worst_outcome(OUTCOME_SUCCEEDED, OUTCOME_FAILED), "FAILED")
```

`--only` selectors parse into a kind and a name, and the final evidence line
says whether the run was full:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_api import SCOPE_SELECTIVE, parse_selector, run_evidence_line, scope_of

var sel = parse_selector("step:build-wheels")
assert_true(sel.is_step())
assert_equal(sel.name, "build-wheels")
var only = List[String]()
only.append(sel.canonical())
assert_equal(scope_of(only), SCOPE_SELECTIVE)
assert_equal(
    run_evidence_line(scope_of(only), "release", only, "SUCCEEDED"),
    "kci: SELECTIVE run of stage release (step:build-wheels): SUCCEEDED -- not a full run",
)
```

A malformed selector is refused, naming what was given:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_api import parse_selector

var message = String()
try:
    _ = parse_selector("stage:x")
except e:
    message = String(e)
assert_equal(message, "--only 'stage:x': 'stage' is not a selector kind (step or validation)")
```

Platforms translate to conda subdirs and OCI spellings, and an artifact
reference always carries its full revision:

<!-- mojo-hidden from std.testing import assert_equal, assert_false -->
```mojo
from kci_api import PLATFORM_LINUX_X86_64, ArtifactRef, conda_subdir_of, is_full_commit_id, oci_platform_of, platform_of_oci

assert_equal(conda_subdir_of(PLATFORM_LINUX_X86_64), "linux-64")
assert_equal(oci_platform_of(PLATFORM_LINUX_X86_64), "linux/amd64")
assert_equal(platform_of_oci("linux/arm64"), "linux-arm64")
assert_false(is_full_commit_id("abc1234"))
var rev = String("0123456789abcdef0123456789abcdef01234567")
var a = ArtifactRef(rev, String(PLATFORM_LINUX_X86_64), String("komira_json"))
assert_equal(a.display(), "komira_json@" + rev + "/linux-x86_64")
```
