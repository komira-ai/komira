"""A stand-in for the pinned tzdata wheel, for test 51's fixtures.

python_oracle's `tzdata` defaults to komira//third_party/python:tzdata, which
is visible only to the test-only packages, so a fixture here must name its
own. This one is a checked-in file (no action builds it), so the independence
check passes it and each fixture is refused for its own planted input.
"""

load("@komira//tools/build/python:defs.bzl", "PythonWheelInfo")

def _impl(ctx):
    return [
        DefaultInfo(),
        PythonWheelInfo(name = "tzdata", version = "0", closure = {"tzdata": ("0", ctx.attrs.site)}),
    ]

stand_in_tzdata = rule(
    impl = _impl,
    attrs = {"site": attrs.source()},
)
