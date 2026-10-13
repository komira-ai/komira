# =============================================================================
# Unit tests for HardwareTopology
# =============================================================================
#
# Design doc: an internal doc (v3, §1.1 + §1.2).
#
# Covers:
#   - Fields constructor preserves inputs.
#   - num_workers() = P + E.
#   - detect() returns a sane topology on the host machine (P >= 1; total <=
#     128 sanity bound; E may be 0 on older Intel or non-asymmetric Linux).
#   - Writable output is non-empty.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_engine_runtime.hardware_topology import HardwareTopology


# -----------------------------------------------------------------------------
# Fields constructor
# -----------------------------------------------------------------------------


def test_fields_constructor() raises:
    """HardwareTopology(p, e) preserves the inputs verbatim."""
    var t = HardwareTopology(4, 6)
    assert_equal(t.num_p_cores, 4)
    assert_equal(t.num_e_cores, 6)


def test_num_workers_sums_p_and_e() raises:
    """The num_workers() sum equals num_p_cores + num_e_cores."""
    var t = HardwareTopology(4, 6)
    assert_equal(t.num_workers(), 10)
    var u = HardwareTopology(8, 0)
    assert_equal(u.num_workers(), 8)
    var v = HardwareTopology(0, 0)
    assert_equal(v.num_workers(), 0)


def test_pure_p_silicon_layout() raises:
    """Older Intel or non-asymmetric Linux presents as (N, 0)."""
    var t = HardwareTopology(16, 0)
    assert_equal(t.num_p_cores, 16)
    assert_equal(t.num_e_cores, 0)
    assert_equal(t.num_workers(), 16)


# -----------------------------------------------------------------------------
# detect()
# -----------------------------------------------------------------------------


def test_detect_returns_sane_values() raises:
    """On any supported platform, detect() yields a plausible layout.

    Invariants:
      - num_p_cores >= 1 (we always need at least one P-tier worker).
      - num_e_cores >= 0.
      - total num_workers <= 128 (sanity bound; no test machine has more).
    """
    var t = HardwareTopology.detect()
    assert_true(t.num_p_cores >= 1)
    assert_true(t.num_e_cores >= 0)
    assert_true(t.num_workers() >= 1)
    assert_true(t.num_workers() <= 128)


def test_detect_is_deterministic() raises:
    """Two consecutive probes on the same machine return the same layout."""
    var a = HardwareTopology.detect()
    var b = HardwareTopology.detect()
    assert_equal(a.num_p_cores, b.num_p_cores)
    assert_equal(a.num_e_cores, b.num_e_cores)


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


def main() raises:
    test_fields_constructor()
    test_num_workers_sums_p_and_e()
    test_pure_p_silicon_layout()
    test_detect_returns_sane_values()
    test_detect_is_deterministic()
    print("test_hardware_topology: 5 tests passed")
