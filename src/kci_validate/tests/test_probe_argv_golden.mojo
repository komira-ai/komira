# =============================================================================
# src/kci_validate/tests/test_probe_argv_golden.mojo
#   A DEPLOY_PROBE's command lines, golden: the probe's `docker run` keeps
#   container.mojo's hardening flags (--read-only, --cap-drop=ALL,
#   no-new-privileges, --pull=never), --network=bridge, no `-e` at all,
#   `--name kci-probe-<id>` and the `kci-probe-max-seconds` label, then the
#   image's args and the two flags kci appends; the pre-flight's `nc -z` to
#   the link-local metadata address with the same hardening; the removal
#   and the sweep's reads. The validation run id: its exact value, its
#   bound, and two ids whose readable parts collide.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_validation_run.validation_run_tag import is_valid_validation_run_id
from kci_validate import (
    daemon_time_argv,
    preflight_run_argv,
    probe_run_argv,
    probe_run_id,
    remove_argv,
    sweep_inspect_argv,
    sweep_list_argv,
)

comptime IMAGE: String = "registry.example.invalid/probe@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
comptime PRE: String = "registry.example.invalid/busybox@sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
comptime ID: String = "gh-42-1-probe-9eff98f29188"


def _join(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        s += String("[") + xs[i] + String("]")
    return s^


def _hardened(name: String, max_seconds: String) -> List[String]:
    var want = List[String]()
    for word in ["run", "--rm", "--pull=never", "--network=bridge", "--name"]:
        want.append(String(word))
    want.append(name.copy())
    want.append(String("--label"))
    want.append(String("kci-probe-max-seconds=") + max_seconds)
    for word in [
        "--user", "1001:118", "--read-only", "--tmpfs", "/tmp:rw,size=256m", "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
    ]:
        want.append(String(word))
    return want^


def test_the_probe_argv_is_golden() raises:
    var args = List[String]()
    args.append(String("--checks=smoke"))
    args.append(String("-v"))
    var got = probe_run_argv(
        String(IMAGE), String("/scratch/probe/work"), String("1001:118"), String(ID), 300, args,
        String("https://api.example.invalid"),
    )
    var want = _hardened(String("kci-probe-") + String(ID), String("360"))
    for word in ["-v", "/scratch/probe/work:/work:rw", "-w", "/work"]:
        want.append(String(word))
    want.append(String(IMAGE))
    want.append(String("--checks=smoke"))
    want.append(String("-v"))
    want.append(String("--validation-run-id=") + String(ID))
    want.append(String("--target-url=https://api.example.invalid"))
    assert_equal(_join(got), _join(want))
    # no environment reaches the container
    for i in range(len(got)):
        assert_false(got[i] == String("-e") or got[i].startswith(String("--env")), got[i])


def test_a_probe_with_no_target_gets_no_target_url() raises:
    var got = probe_run_argv(
        String(IMAGE), String("/scratch/probe/work"), String("1001:118"), String(ID), 5, List[String](), String("")
    )
    assert_equal(got[len(got) - 1], String("--validation-run-id=") + String(ID))
    assert_equal(got[len(got) - 2], String(IMAGE))
    assert_equal(got[7], String("kci-probe-max-seconds=65"))


def test_the_preflight_argv_is_golden() raises:
    var want = _hardened(String("kci-preflight-") + String(ID), String("120"))
    want.append(String(PRE))
    for word in ["nc", "-z", "-w", "3", "169.254.169.254", "80"]:
        want.append(String(word))
    assert_equal(_join(preflight_run_argv(String(PRE), String("1001:118"), String(ID))), _join(want))


def test_the_removal_and_the_sweep_reads_are_golden() raises:
    assert_equal(_join(remove_argv(String("kci-probe-x"))), String("[rm][-f][kci-probe-x]"))
    assert_equal(
        _join(sweep_list_argv()),
        String("[ps][-a][--no-trunc][--filter][label=kci-probe-max-seconds][--format][{{.ID}}]"),
    )
    var ids = List[String]()
    ids.append(String("c1"))
    ids.append(String("c2"))
    assert_equal(
        _join(sweep_inspect_argv(ids)),
        String("[inspect][--format][{{.Id}} {{.State.StartedAt}} {{.Created}} {{index .Config.Labels \"kci-probe-max-seconds\"}}][c1][c2]"),
    )
    assert_equal(_join(daemon_time_argv()), String("[info][--format][{{.SystemTime}}]"))


def test_the_validation_run_id() raises:
    assert_equal(probe_run_id(String("gh-42"), 1, String("probe")), String(ID))
    # every input counts
    assert_true(probe_run_id(String("gh-43"), 1, String("probe")) != String(ID))
    assert_true(probe_run_id(String("gh-42"), 2, String("probe")) != String(ID))
    assert_true(probe_run_id(String("gh-42"), 1, String("probe2")) != String(ID))
    # the same readable part, two ids
    var a = probe_run_id(String("x-1"), 2, String("p"))
    var b = probe_run_id(String("x"), 1, String("2-p"))
    assert_equal(a, String("x-1-2-p-42f71fd22556"))
    assert_equal(b, String("x-1-2-p-bd003e7f135c"))
    # long inputs are cut, and the id stays label-safe and at most 63 bytes
    var long_run = String("")
    for _ in range(63):
        long_run += String("r")
    var long_name = String("")
    for _ in range(6):
        long_name += String("Probe.Name_")
    var c = probe_run_id(long_run, 123456789, long_name)
    assert_true(c.byte_length() <= 63, c)
    assert_true(is_valid_validation_run_id(c), c)
    assert_true(is_valid_validation_run_id(String(ID)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
