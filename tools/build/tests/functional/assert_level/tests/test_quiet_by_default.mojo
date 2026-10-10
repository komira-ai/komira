# Passes when all_only_probe's debug_assert is not compiled in: at the default
# level (and none). Its twin tests//negative/assert_level:lib_all runs it at
# ASSERT=all, where the assert fires.
from alevel import all_only_probe
from std.testing import assert_equal


def main() raises:
    assert_equal(all_only_probe(1), 2, "all_only_probe returned past its assert")
