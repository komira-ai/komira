"""libgate_ok: a library whose own test is part of its build.

`buck2 build` of this library runs tests/test_payload_passes.mojo; the
package exists only if that test passes.
"""

from .payload import GatePayload, payload_width
