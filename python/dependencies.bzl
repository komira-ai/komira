"""The version ranges of the distributions the Python package (pip install
komira-ai) imports: the `Requires-Dist` lines its wheel will declare. Nothing
packages the wheel yet; the tests of python/tests read these ranges today.

`PROTOBUF_REQUIREMENT` is the protobuf runtime the generated plan modules
(`komira.plan.v1`, python/BUCK) load under:

- the lower bound is the version of the gencode the pinned protoc (29.1)
  writes, 5.29.1: the runtime refuses gencode newer than itself, so 5.29.1 is
  the oldest runtime that loads it;
- the upper bound excludes the next major, 8: 7.36.2 is the newest runtime the
  tests load the modules under, and no 8.x release exists to test.

python/tests runs the modules under both edges, 5.29.1 and 7.36.2, and under
5.28.3, the release below the range, which must refuse them; each test reads
this string, so a bound moved without its test fails there.
"""

PROTOBUF_REQUIREMENT = "protobuf>=5.29.1,<8"
