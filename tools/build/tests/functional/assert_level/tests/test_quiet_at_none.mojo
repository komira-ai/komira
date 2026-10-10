# Passes only when neither probe's debug_assert is compiled in: at
# ASSERT=none. Its twin tests//negative/assert_level:lib_safe_default runs it at
# the default level, where safe_probe's assert fires.
from alevel import all_only_probe, safe_probe
from std.testing import assert_equal


def main() raises:
    assert_equal(safe_probe(1), 2, "safe_probe returned past its assert")
    assert_equal(all_only_probe(1), 2, "all_only_probe returned past its assert")
