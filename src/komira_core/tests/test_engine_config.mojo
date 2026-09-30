# =============================================================================
# EngineConfig unit tests
# =============================================================================
#
# Tests effective_readers* and effective_concurrent_writes under various
# storage profiles, explicit overrides, and workload types.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.engine_config import (
    EngineConfig,
    STORAGE_LOCAL_NVME,
    STORAGE_REMOTE_S3,
    NVME_DEFAULT_READERS,
    S3_DEFAULT_READERS,
    NVME_DEFAULT_WRITES,
    S3_DEFAULT_WRITES,
    DEFAULT_BATCH_SIZE,
    DEFAULT_MAX_IN_FLIGHT,
    DEFAULT_ROWS_PER_GROUP,
)
from komira_core.arrow.offset_overflow import ARROW_INT32_OFFSET_MAX
from komira_core.runtime.engine_placement import EnginePlacement
from komira_core.runtime.thp_policy import (
    ADVICE_HUGEPAGE,
    ADVICE_OFF,
    ADVICE_POPULATE,
)


# --- Default values ----------------------------------------------------------

def test_default_config() raises:
    """Default config values."""
    var cfg = EngineConfig()
    assert_equal(cfg.storage_profile, STORAGE_LOCAL_NVME)
    assert_equal(cfg.reader_threads, 0)
    assert_equal(cfg.max_in_flight, DEFAULT_MAX_IN_FLIGHT)
    assert_equal(cfg.batch_size, DEFAULT_BATCH_SIZE)
    assert_equal(cfg.rows_per_group, DEFAULT_ROWS_PER_GROUP)
    assert_equal(cfg.max_concurrent_writes, 0)
    assert_equal(cfg.memory_budget_bytes, 0)


# --- effective_readers (general) ---------------------------------------------

def test_nvme_default_readers() raises:
    """NVMe profile defaults to 2 readers."""
    var cfg = EngineConfig()
    assert_equal(cfg.effective_readers(10), NVME_DEFAULT_READERS)


def test_s3_default_readers() raises:
    """S3 profile defaults to 8 readers."""
    var cfg = EngineConfig().with_storage_profile(STORAGE_REMOTE_S3)
    assert_equal(cfg.effective_readers(100), S3_DEFAULT_READERS)


def test_readers_capped_by_row_groups() raises:
    """Reader count capped by available row groups."""
    var cfg = EngineConfig().with_storage_profile(STORAGE_REMOTE_S3)
    # S3 wants 8, but only 3 row groups available.
    assert_equal(cfg.effective_readers(3), 3)


def test_explicit_override_readers() raises:
    """Explicit reader_threads overrides profile default."""
    var cfg = EngineConfig().with_reader_threads(4)
    assert_equal(cfg.effective_readers(100), 4)


def test_readers_at_least_one() raises:
    """Always at least 1 reader even with 0 row groups edge case."""
    var cfg = EngineConfig()
    # Clamp ensures min=1 even when num_row_groups might suggest 0.
    assert_true(cfg.effective_readers(1) >= 1)


# --- effective_readers_for_bypass --------------------------------------------

def test_bypass_high_ratio_scales_up() raises:
    """High bypass ratio (>= 0.5) scales readers beyond NVMe default."""
    var cfg = EngineConfig()
    var readers = cfg.effective_readers_for_bypass(49, 0.8125)
    assert_true(readers > 2, "expected > 2 for high bypass ratio, got " + String(readers))
    assert_true(readers <= 8, "expected <= 8 for high bypass ratio, got " + String(readers))


def test_bypass_low_ratio_uses_default() raises:
    """Low bypass ratio (< 0.5) falls back to NVMe default."""
    var cfg = EngineConfig()
    assert_equal(cfg.effective_readers_for_bypass(49, 0.3), NVME_DEFAULT_READERS)


def test_bypass_explicit_override() raises:
    """Explicit override takes priority."""
    var cfg = EngineConfig().with_reader_threads(4)
    assert_equal(cfg.effective_readers_for_bypass(49, 0.9), 4)


def test_bypass_capped_by_row_groups() raises:
    """Bypass readers capped by row groups."""
    var cfg = EngineConfig()
    assert_equal(cfg.effective_readers_for_bypass(3, 0.9), 3)


def test_bypass_boundary_at_half() raises:
    """Boundary at bypass_ratio = 0.5."""
    var cfg = EngineConfig()
    var at_half = cfg.effective_readers_for_bypass(49, 0.5)
    assert_true(at_half > 2, "bypass_ratio=0.5 should scale up, got " + String(at_half))
    var below_half = cfg.effective_readers_for_bypass(49, 0.49)
    assert_equal(below_half, NVME_DEFAULT_READERS)


# --- effective_readers_for_aggregate -----------------------------------------

def test_aggregate_scales_to_cores() raises:
    """Aggregation defaults to num_cpus (capped at 16)."""
    var cfg = EngineConfig()
    var readers = cfg.effective_readers_for_aggregate(100)
    # Should be > NVMe default of 2 (compute-bound workload).
    assert_true(readers > 2, "agg should scale beyond 2, got " + String(readers))
    assert_true(readers <= 16, "agg capped at 16, got " + String(readers))


def test_aggregate_explicit_override() raises:
    """Explicit override takes priority for aggregate."""
    var cfg = EngineConfig().with_reader_threads(3)
    assert_equal(cfg.effective_readers_for_aggregate(100), 3)


def test_aggregate_capped_by_row_groups() raises:
    """Aggregate readers capped by row groups."""
    var cfg = EngineConfig()
    var readers = cfg.effective_readers_for_aggregate(2)
    assert_equal(readers, 2)


# --- effective_readers_for_join ----------------------------------------------

def test_join_scales_to_cores() raises:
    """Join probe defaults to num_cpus (capped at 16)."""
    var cfg = EngineConfig()
    var readers = cfg.effective_readers_for_join(100)
    assert_true(readers > 2, "join should scale beyond 2, got " + String(readers))
    assert_true(readers <= 16, "join capped at 16, got " + String(readers))


def test_join_explicit_override() raises:
    """Explicit override takes priority for join."""
    var cfg = EngineConfig().with_reader_threads(5)
    assert_equal(cfg.effective_readers_for_join(100), 5)


# --- effective_concurrent_writes ---------------------------------------------

def test_nvme_default_writes() raises:
    """NVMe defaults to 1 concurrent write."""
    var cfg = EngineConfig()
    assert_equal(cfg.effective_concurrent_writes(), NVME_DEFAULT_WRITES)


def test_s3_default_writes() raises:
    """S3 defaults to 8 concurrent writes."""
    var cfg = EngineConfig().with_storage_profile(STORAGE_REMOTE_S3)
    assert_equal(cfg.effective_concurrent_writes(), S3_DEFAULT_WRITES)


def test_explicit_override_writes() raises:
    """Explicit override takes priority."""
    var cfg = EngineConfig().with_max_concurrent_writes(12)
    assert_equal(cfg.effective_concurrent_writes(), 12)


# --- Builder-style API -------------------------------------------------------

def test_builder_chain() raises:
    """Builder methods produce correct config."""
    var cfg = (
        EngineConfig()
        .with_reader_threads(6)
        .with_batch_size(4096)
        .with_rows_per_group(500000)
        .with_storage_profile(STORAGE_REMOTE_S3)
        .with_memory_budget(1024 * 1024 * 1024)
        .with_max_concurrent_writes(4)
    )
    assert_equal(cfg.reader_threads, 6)
    assert_equal(cfg.batch_size, 4096)
    assert_equal(cfg.rows_per_group, 500000)
    assert_equal(cfg.storage_profile, STORAGE_REMOTE_S3)
    assert_equal(cfg.memory_budget_bytes, 1024 * 1024 * 1024)
    assert_equal(cfg.max_concurrent_writes, 4)


# --- Runtime configuration: placement / memory advice / offset promotion ---

def test_runtime_config_defaults() raises:
    """`EngineConfig()` is the unconfigured engine: every placement policy
    off, no memory advice, and offset promotion at the real Int32 ceiling."""
    var cfg = EngineConfig()
    assert_true(cfg.placement == EnginePlacement(), "default placement")
    assert_equal(cfg.memory_advice, ADVICE_OFF)
    assert_equal(cfg.offset_promote_at, ARROW_INT32_OFFSET_MAX)


def test_runtime_config_builders() raises:
    """The builders set the runtime fields, masking the advice bits and
    clamping the promotion trip point to the real ceiling."""
    var p = EnginePlacement(pin_workers=True, io_lane=True)
    var cfg = (
        EngineConfig()
        .with_placement(p)
        .with_memory_advice(ADVICE_HUGEPAGE)
        .with_offset_promote_at(100)
    )
    assert_true(cfg.placement == p, "placement builder")
    assert_equal(cfg.memory_advice, ADVICE_HUGEPAGE)
    assert_equal(cfg.offset_promote_at, 100)
    # Bits outside HUGEPAGE | POPULATE are dropped.
    assert_equal(
        EngineConfig().with_memory_advice(0xFF).memory_advice,
        ADVICE_HUGEPAGE | ADVICE_POPULATE,
    )
    # Out-of-range trip points become the ceiling.
    assert_equal(
        EngineConfig().with_offset_promote_at(0).offset_promote_at,
        ARROW_INT32_OFFSET_MAX,
    )
    assert_equal(
        EngineConfig()
        .with_offset_promote_at(ARROW_INT32_OFFSET_MAX + 1)
        .offset_promote_at,
        ARROW_INT32_OFFSET_MAX,
    )


# --- Writable ----------------------------------------------------------------

def test_writable() raises:
    """EngineConfig can be printed."""
    var cfg = EngineConfig()
    var s = String(cfg)
    assert_true(s.byte_length() > 0, "str() should produce non-empty output")
    assert_true("EngineConfig" in s, "output should contain 'EngineConfig'")


# --- Entry point -------------------------------------------------------------

def main() raises:
    test_default_config()
    test_nvme_default_readers()
    test_s3_default_readers()
    test_readers_capped_by_row_groups()
    test_explicit_override_readers()
    test_readers_at_least_one()
    test_bypass_high_ratio_scales_up()
    test_bypass_low_ratio_uses_default()
    test_bypass_explicit_override()
    test_bypass_capped_by_row_groups()
    test_bypass_boundary_at_half()
    test_aggregate_scales_to_cores()
    test_aggregate_explicit_override()
    test_aggregate_capped_by_row_groups()
    test_join_scales_to_cores()
    test_join_explicit_override()
    test_nvme_default_writes()
    test_s3_default_writes()
    test_explicit_override_writes()
    test_builder_chain()
    test_runtime_config_defaults()
    test_runtime_config_builders()
    test_writable()
    print("test_engine_config: 21 tests passed")
