"""libgate_bad: a library whose own test FAILS ON PURPOSE.

Building `checks//libgate_bad:libgate_bad` must fail; building its
`[ungated]` sub-target must succeed. Together they show the red comes from the
test gate, not from the compile.
"""

from .payload import GatePayload, payload_width
