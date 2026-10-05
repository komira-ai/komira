# =============================================================================
# src/kci_release_machine/tests/test_release_validation_targets.mojo
#   release/validations/BUCK declares one runnable target per validation of
#   release/machine.textproto (`./buck2 run //release/validations:<name>`).
#   This holds the two sets equal BOTH WAYS: every validation of every stage
#   has a target of its name and stage, and every target names a validation
#   of that stage. Each target runs `kci run --stage <stage> --only
#   validation:<name>` and nothing else selects what runs.
# =============================================================================
#
# Test data (BUCK): `machine.textproto` (release/BUCK) and `names.txt`
# (//release/validations:names: one line per target, `<name> <stage> <kci>
# <argv...>`, written from the same list the target runs).
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from kci_release_machine import ReleaseMachine, parse_machine_file


def _validations() raises -> List[String]:
    """`<name> <stage>` for every validation of the machine file, in file order."""
    var g = parse_machine_file(Path(String("machine.textproto")).read_text(), String("release/machine.textproto"))
    var out = List[String]()
    for i in range(len(g.stages)):
        for k in range(len(g.stages[i].steps)):
            for m in range(len(g.stages[i].steps[k].validations)):
                out.append(g.stages[i].steps[k].validations[m].name + String(" ") + g.stages[i].name)
    return out^


def _targets() raises -> List[List[String]]:
    """Each line of names.txt as its words."""
    var out = List[List[String]]()
    var lines = Path(String("names.txt")).read_text().split(String("\n"))
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var words = List[String]()
        var parts = line.split(String(" "))
        for p in range(len(parts)):
            words.append(String(parts[p]))
        out.append(words^)
    return out^


def _has(names: List[String], want: String) -> Bool:
    for i in range(len(names)):
        if names[i] == want:
            return True
    return False


def test_every_validation_has_a_target_and_every_target_a_validation() raises:
    var vals = _validations()
    var targets = _targets()
    # never a vacuous pass: the machine file declares validations
    assert_true(len(vals) > 0, String("release/machine.textproto declares no validation"))
    var have = List[String]()
    for i in range(len(targets)):
        assert_true(len(targets[i]) >= 2, String("names.txt: a line without a name and a stage"))
        have.append(targets[i][0] + String(" ") + targets[i][1])
    for i in range(len(vals)):
        assert_true(
            _has(have, vals[i]),
            String("validation '") + vals[i] + String("' of release/machine.textproto has no target in release/validations/BUCK"),
        )
    for i in range(len(have)):
        assert_true(
            _has(vals, have[i]),
            String("release/validations/BUCK declares '") + have[i]
            + String("', which is no validation of that stage in release/machine.textproto"),
        )
    assert_equal(len(have), len(vals))


def test_each_target_runs_its_own_validation_and_stage() raises:
    var targets = _targets()
    assert_true(len(targets) > 0, String("release/validations declares no target"))
    for i in range(len(targets)):
        ref w = targets[i]
        var where = String("target '") + w[0] + String("'")
        assert_true(len(w) >= 7, where + String(": too few arguments"))
        assert_equal(w[2], String("<kci>"), where)
        assert_equal(w[3], String("run"), where)
        var stages = 0
        var only = 0
        for k in range(4, len(w)):
            if w[k] == String("--stage"):
                stages += 1
                assert_true(k + 1 < len(w) and w[k + 1] == w[1], where + String(": --stage is not its stage ") + w[1])
            if w[k] == String("--only"):
                only += 1
                assert_true(
                    k + 1 < len(w) and w[k + 1] == String("validation:") + w[0],
                    where + String(": --only is not validation:") + w[0],
                )
        assert_equal(stages, 1, where + String(": --stage given ") + String(stages) + String(" times"))
        assert_equal(only, 1, where + String(": --only given ") + String(only) + String(" times"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
