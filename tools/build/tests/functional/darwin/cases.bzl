"""Load-time cases of `darwin_properties_refusal` (run by tools/build/tests/functional/darwin/BUCK)."""

load("@komira//tools/build/platforms:defs.bzl", "DARWIN_LOCAL_HOST", "darwin_local_hosts_refusal", "darwin_properties_refusal", "darwin_toolchain_hosts")

# Load-time cases of `darwin_properties_refusal`: a macOS property set is
# registered only with a non-empty property dict and at least one well-formed
# host identity in `[komira_re] darwin_macos_hosts`. Loading this package
# (tools/build/tests/functional/darwin/check.sh runs `buck2 targets tests//functional/darwin:`)
# fails if any case gets the wrong answer.
_CASES = [
    # (properties, host identities, refused?)
    ({"pool": "macos"}, ["26.5-0123456789abcdef"], False),
    ({"pool": "macos"}, ["26.5-0123456789abcdef", "26.5-fedcba9876543210"], False),
    ({"pool": "macos"}, [], True),
    ({}, ["26.5-0123456789abcdef"], True),
    ({"pool": "macos"}, ["0123456789abcdef"], True),
    ({"pool": "macos"}, ["26.5-"], True),
    # Regression pin: the local sentinel has no `-`, so it is no identity and a worker set cannot list it.
    ({"pool": "macos"}, [DARWIN_LOCAL_HOST], True),
]

# (hosts, local_execution) -> refused? The toolchain rule's guard.
_LOCAL_CASES = [
    (["26.5-0123456789abcdef"], False, False),
    ([DARWIN_LOCAL_HOST], True, False),
    ([], False, False),
    ([DARWIN_LOCAL_HOST], False, True),
    ([DARWIN_LOCAL_HOST, "26.5-0123456789abcdef"], False, True),
    ([DARWIN_LOCAL_HOST, "26.5-0123456789abcdef"], True, True),
    (["26.5-0123456789abcdef"], True, True),
    ([], True, True),
]

# (hosts named, execution mode, host row) -> (toolchain hosts, local?).
_TOOLCHAIN_CASES = [
    # The farm: hosts named, whatever the mode; nothing changes.
    (["26.5-0123456789abcdef"], "remote", "linux-x86_64", (["26.5-0123456789abcdef"], False)),
    (["26.5-0123456789abcdef"], "local", "darwin-arm64", (["26.5-0123456789abcdef"], False)),
    # A native Mac build: no hosts, local, a Mac.
    ([], "local", "darwin-arm64", ([DARWIN_LOCAL_HOST], True)),
    # Never the sentinel: remote mode, or a host that is not a Mac.
    ([], "remote", "darwin-arm64", ([], False)),
    ([], "remote", "linux-x86_64", ([], False)),
    ([], "local", "linux-x86_64", ([], False)),
    ([], "local", None, ([], False)),
]

def darwin_properties_cases():
    for props, hosts, refused in _CASES:
        got = darwin_properties_refusal(props, hosts)
        if (got != None) != refused:
            fail("darwin_properties_refusal({}, {}) = {}, expected {}".format(
                props,
                repr(hosts),
                repr(got),
                "a refusal" if refused else "None",
            ))

    for hosts, mode, host_name, want in _TOOLCHAIN_CASES:
        got = darwin_toolchain_hosts(hosts, mode, host_name)
        if got != want:
            fail("darwin_toolchain_hosts({}, {}, {}) = {}, expected {}".format(repr(hosts), repr(mode), repr(host_name), repr(got), repr(want)))

    for hosts, local, refused in _LOCAL_CASES:
        got = darwin_local_hosts_refusal(hosts, local)
        if (got != None) != refused:
            fail("darwin_local_hosts_refusal({}, {}) = {}, expected {}".format(repr(hosts), repr(local), repr(got), "a refusal" if refused else "None"))
