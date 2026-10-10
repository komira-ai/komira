# =============================================================================
# src/kci_validate/probe_container.mojo -- the exact `docker` command lines of
#   a DEPLOY_PROBE validation: the pre-flight, the probe, the removal by name,
#   and the reads of the expiry sweep; the probe's validation run id.
# =============================================================================
#
# THE VALIDATION RUN ID (`probe_run_id`) is derived from --run-id, --attempt
# and the validation's name, so two runs, two attempts or two probes never
# share one: a readable part `<run id>-<attempt>-<name>` (bytes outside
# [a-z0-9_-] become `-`, cut to PROBE_RUN_ID_READABLE_BYTES), then `-` and the
# first 12 hex digits of the sha256 of the three values joined by newlines.
# The hash keeps it unique where the readable part is ambiguous (run `x-1`
# attempt 2 and run `x` attempt 1 of the probe `2-p` both read `x-1-2-p`)
# or cut. It is at most 63 bytes of [a-z0-9_-]: komira_validation_run's
# `is_valid_validation_run_id`.
#
# THE PROBE (`probe_run_argv`), container.mojo's hardening and no
# environment at all:
#
#   docker run --rm --pull=never --network=bridge
#     --name kci-probe-<id> --label kci-probe-max-seconds=<timeout + 60>
#     --user <uid>:<gid> --read-only --tmpfs /tmp:rw,size=256m
#     --cap-drop=ALL --security-opt=no-new-privileges
#     -v <scratch>/<validation>/work:/work:rw -w /work
#     <image> <args...> --validation-run-id=<id> [--target-url=<url>]
#
# The name lets kci remove the container when its own timeout ends the
# docker client (`remove_argv`: `docker rm -f <name>`); the label is a
# maximum DURATION counted from the container's own start, read by the sweep
# (probe_sweep.mojo), never a clock reading.
#
# THE PRE-FLIGHT (`preflight_run_argv`): the same hardening and network, the
# digest-pinned helper image (--preflight-image), nothing mounted, and the
# command `nc -z -w <PREFLIGHT_CONNECT_WAIT_S> 169.254.169.254 80`: exit 0
# is "the link-local metadata address answered", exit 1 "it did not". It is
# named `kci-preflight-<id>` and carries the same label, so a pre-flight
# kci's timeout ends is removed by name and one kci never removed is swept.
#
# THE SWEEP'S READS (`sweep_list_argv`, `sweep_inspect_argv`,
# `daemon_time_argv`): every container with the label, each one's id, start,
# creation and label, and the daemon's own clock (`docker info`).
#
# Pure functions over owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_crypto import hex_lower_array_32, sha256_string

from .container import WORK_MOUNT

comptime PROBE_NAME_PREFIX: String = "kci-probe-"
comptime PREFLIGHT_NAME_PREFIX: String = "kci-preflight-"
comptime PROBE_MAX_SECONDS_LABEL: String = "kci-probe-max-seconds"
"""The label holding a probe container's maximum duration in seconds."""
comptime PROBE_LABEL_GRACE_S: Int = 60
"""Added to a probe's timeout_seconds in its label: kci itself removes the
container at its timeout, so only a container kci never removed outlives
this."""
comptime PREFLIGHT_ADDRESS: String = "169.254.169.254"
"""The link-local metadata address the pre-flight connects to (written in
words in docs/ci.md)."""
comptime PREFLIGHT_PORT: String = "80"
comptime PREFLIGHT_CONNECT_WAIT_S: Int = 3
"""`nc -w`: how long the pre-flight's connect waits."""
comptime PREFLIGHT_TIMEOUT_S: Int = 60
"""kci's own timeout around the pre-flight container."""
comptime PROBE_PULL_TIMEOUT_S: Int = 900
comptime DOCKER_SHORT_TIMEOUT_S: Int = 60
"""`docker rm -f`, `ps`, `inspect` and `info`."""
comptime PROBE_RUN_ID_READABLE_BYTES: Int = 50
comptime PROBE_RUN_ID_HASH_HEX: Int = 12


def _label_safe(s: String) -> String:
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45:
            out += chr(c)
        elif c >= 65 and c <= 90:
            out += chr(c + 32)
        else:
            out += String("-")
    return out^


def probe_run_id(run_id: String, attempt: Int, name: String) -> String:
    """The probe's validation run id (file header)."""
    var full = _label_safe(run_id + String("-") + String(attempt) + String("-") + name)
    var readable = full.copy()
    if full.byte_length() > PROBE_RUN_ID_READABLE_BYTES:
        readable = String(full[byte = 0:PROBE_RUN_ID_READABLE_BYTES])
    var digest = hex_lower_array_32(sha256_string(run_id + String("\n") + String(attempt) + String("\n") + name))
    return readable + String("-") + String(digest[byte = 0:PROBE_RUN_ID_HASH_HEX])


def probe_container_name(run_id: String) -> String:
    return String(PROBE_NAME_PREFIX) + run_id


def preflight_container_name(run_id: String) -> String:
    return String(PREFLIGHT_NAME_PREFIX) + run_id


def _hardening(mut a: List[String], name: String, max_seconds: Int, user: String):
    """`run --rm --pull=never --network=bridge`, the name, the label, the
    user and container.mojo's hardening flags."""
    for word in ["run", "--rm", "--pull=never", "--network=bridge", "--name"]:
        a.append(String(word))
    a.append(name.copy())
    a.append(String("--label"))
    a.append(String(PROBE_MAX_SECONDS_LABEL) + String("=") + String(max_seconds))
    a.append(String("--user"))
    a.append(user.copy())
    for word in [
        "--read-only", "--tmpfs", "/tmp:rw,size=256m", "--cap-drop=ALL", "--security-opt=no-new-privileges",
    ]:
        a.append(String(word))


def probe_run_argv(
    image: String,
    work_dir: String,
    user: String,
    run_id: String,
    timeout_seconds: Int,
    args: List[String],
    target_url: String,
) -> List[String]:
    """`docker run ...` of the probe (file header), argv without the
    program. `target_url` "" appends no --target-url."""
    var a = List[String]()
    _hardening(a, probe_container_name(run_id), timeout_seconds + PROBE_LABEL_GRACE_S, user)
    a.append(String("-v"))
    a.append(work_dir + String(":") + String(WORK_MOUNT) + String(":rw"))
    a.append(String("-w"))
    a.append(String(WORK_MOUNT))
    a.append(image.copy())
    for i in range(len(args)):
        a.append(args[i].copy())
    a.append(String("--validation-run-id=") + run_id)
    if target_url.byte_length() > 0:
        a.append(String("--target-url=") + target_url)
    return a^


def preflight_run_argv(image: String, user: String, run_id: String) -> List[String]:
    """`docker run ...` of the pre-flight (file header)."""
    var a = List[String]()
    _hardening(a, preflight_container_name(run_id), PREFLIGHT_TIMEOUT_S + PROBE_LABEL_GRACE_S, user)
    a.append(image.copy())
    for word in ["nc", "-z", "-w"]:
        a.append(String(word))
    a.append(String(PREFLIGHT_CONNECT_WAIT_S))
    a.append(String(PREFLIGHT_ADDRESS))
    a.append(String(PREFLIGHT_PORT))
    return a^


def remove_argv(name: String) -> List[String]:
    """`docker rm -f <name or id>`."""
    var a = List[String]()
    a.append(String("rm"))
    a.append(String("-f"))
    a.append(name.copy())
    return a^


def sweep_list_argv() -> List[String]:
    """Every container, running or not, that carries the label: one id per
    line."""
    var a = List[String]()
    for word in ["ps", "-a", "--no-trunc", "--filter"]:
        a.append(String(word))
    a.append(String("label=") + String(PROBE_MAX_SECONDS_LABEL))
    a.append(String("--format"))
    a.append(String("{{.ID}}"))
    return a^


def sweep_inspect_argv(ids: List[String]) -> List[String]:
    """One line per id: `<id> <StartedAt> <Created> <label value>`."""
    var a = List[String]()
    a.append(String("inspect"))
    a.append(String("--format"))
    a.append(
        String("{{.Id}} {{.State.StartedAt}} {{.Created}} {{index .Config.Labels \"")
        + String(PROBE_MAX_SECONDS_LABEL) + String("\"}}")
    )
    for i in range(len(ids)):
        a.append(ids[i].copy())
    return a^


def daemon_time_argv() -> List[String]:
    """The daemon's own clock, with the daemon host's offset."""
    var a = List[String]()
    a.append(String("info"))
    a.append(String("--format"))
    a.append(String("{{.SystemTime}}"))
    return a^
