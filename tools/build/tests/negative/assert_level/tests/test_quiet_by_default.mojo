# The test of tests//functional/assert_level:lib_default, run here at
# ASSERT=all (lib_all), where all_only_probe's debug_assert fires.
from alevel import all_only_probe
from std.testing import assert_equal


def main() raises:
    assert_equal(all_only_probe(1), 2, "all_only_probe returned past its assert")
