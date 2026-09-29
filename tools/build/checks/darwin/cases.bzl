"""Load-time cases of `darwin_properties_refusal` (run by checks/darwin/BUCK)."""

load("@komira//tools/build/platforms:defs.bzl", "darwin_properties_refusal")

# Load-time cases of `darwin_properties_refusal`: a macOS property set is
# registered only if it carries `macos_host` and that value equals the one the
# macOS toolchain promises. A standalone checkout reads both from the same
# `[komira_re]` key, so only a repository that passes the dict itself can make
# them disagree; these cases cover that path without one. Loading this package
# (checks/darwin/check.sh runs `buck2 targets checks//darwin:`) fails if any
# case gets the wrong answer.
_CASES = [
    # (properties, toolchain's value, refused?)
    ({"pool": "mac", "macos_host": "26.5-0123456789abcdef"}, "26.5-0123456789abcdef", False),
    ({"pool": "mac", "macos_host": "26.5-0123456789abcdef"}, "26.5-fedcba9876543210", True),
    ({"pool": "mac", "macos_host": "26.5-0123456789abcdef"}, "", True),
    ({"pool": "mac"}, "26.5-0123456789abcdef", True),
    ({"pool": "mac", "macos_host": ""}, "", True),
]

def darwin_properties_cases():
    for props, toolchain_host, refused in _CASES:
        got = darwin_properties_refusal(props, toolchain_host)
        if (got != None) != refused:
            fail("darwin_properties_refusal({}, {}) = {}, expected {}".format(
                props,
                repr(toolchain_host),
                repr(got),
                "a refusal" if refused else "None",
            ))
