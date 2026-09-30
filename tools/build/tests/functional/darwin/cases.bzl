"""Load-time cases of `darwin_properties_refusal` (run by tools/build/tests/functional/darwin/BUCK)."""

load("@komira//tools/build/platforms:defs.bzl", "darwin_properties_refusal")

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
