# =============================================================================
# test_corpus.mojo -- every registered case, through every check in corpus.mojo.
# =============================================================================
#
# The data root is the test's working directory: BUCK stages expect/,
# datasets/ and inputs/ there. For every case: it builds; plan_to_bytes encodes it;
# plan_wire_admit accepts the bytes; plan_wire_check_values accepts the plan;
# plan_from_bytes decodes it with the same structural hash and root output
# schema; its one expectation file parses, carries its derivation, states the
# case's order/float policy and has the plan's root output schema. Also: every
# case is in exactly one shard, every file under expect/, datasets/ and
# inputs/ belongs to a case, dataset or registered input, every registered
# input is staged, and every dataset matches its declared schema. Every
# problem is reported in one failure, not only the first.
# =============================================================================

from std.testing import TestSuite

from komira_plan_conformance import require_corpus, registered_cases


def test_corpus() raises:
    require_corpus(String("."))


def test_corpus_is_not_empty() raises:
    # A registry that lost its shards would pass every check vacuously.
    if len(registered_cases()) < 109:
        raise Error(
            "plan_conformance: " + String(len(registered_cases()))
            + " cases registered, the twelve shards hold 109"
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
