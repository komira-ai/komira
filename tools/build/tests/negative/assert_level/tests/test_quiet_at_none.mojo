# The test of tests//functional/assert_level:lib_none, run here at the default
# level (lib_safe_default), where safe_probe's debug_assert fires.
from alevel import all_only_probe, safe_probe
from std.testing import assert_equal


def main() raises:
    assert_equal(safe_probe(1), 2, "safe_probe returned past its assert")
    assert_equal(all_only_probe(1), 2, "all_only_probe returned past its assert")
