# =============================================================================
# test_localmodel_fit.mojo
#   The pure "will it run" fit signal over a {hardware} x {model variant}
#   matrix, plus the HostMemoryProfile value type and its pure parse helpers.
# =============================================================================
#
# WHAT THIS PROVES:
#
#   (1) FIT-MATRIX RATINGS — fit(variant, hw) across the fixture matrix
#       {96GB-unified-Mac, 16GB-Mac, 64GB-Linux+24GB-NVIDIA, 32GB-Linux-CPU} x
#       {gpt-oss-120b-MXFP4 62GB, Llama-3.3-70B-Q6 50GB, Qwen-7B-4bit 4GB}
#       matches the expected green/yellow/red ratings.
#   (2) THE NO-FALSE-GREEN PROPERTY — a model that would SPILL the budget is RED
#       (or at worst YELLOW), NEVER green. Asserted over the whole matrix: every
#       variant whose conservative resident estimate exceeds the budget is RED,
#       and every GREEN variant's estimate is comfortably below budget.
#   (3) THE GPU-VRAM WALL — on the discrete-GPU host (64GB RAM + 24GB VRAM) the
#       budget is VRAM (24GB), NOT the 64GB system RAM, so a 50-62GB model is
#       RED.
#   (4) THE YELLOW BAND — a variant that fits but tightly (above the GREEN
#       headroom margin, at/below budget) is YELLOW.
#   (5) auto_pick_highest_green_quant — GREEN first, the highest-quality GREEN
#       variant; falls back to the best YELLOW when none fit GREEN; reports
#       not-found (all RED) with the closest-miss variant.
#   (6) HostMemoryProfile derived views (gpu_budget_bytes / has_discrete_gpu)
#       + the pure /proc/meminfo + nvidia-smi parse helpers.
#   (7) concurrency-aware fit: the KV term scales with concurrent streams.
#   (8) the embed family: KV = 0, footprint is weights only.
#
# PURE: no I/O, no process spawn — every assertion is a pure function of
# fixture value types.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_localmodel import (
    HostMemoryProfile,
    PLATFORM_MACOS,
    PLATFORM_LINUX,
    FitResult,
    ModelVariant,
    CatalogEntry,
    FIT_GREEN,
    FIT_YELLOW,
    FIT_RED,
    fit,
    fit_concurrent,
    auto_pick_highest_green_quant,
    estimate_resident_bytes,
    estimate_resident_bytes_concurrent,
    model_footprint_bytes,
    kv_cache_bytes,
    kv_cache_bytes_concurrent,
    fit_rating_name,
    DEFAULT_CONTEXT_TOKENS,
    DEFAULT_MAX_CONCURRENT,
)
from komira_localmodel.host_profile import (
    _parse_meminfo_total_kb,
    _sum_nvidia_mib_lines,
    _first_uint_token,
)
from komira_localmodel.fit_resolver import (
    fit_with_context,
    OS_HEADROOM_BYTES,
)


comptime GiB: Int = 1024 * 1024 * 1024


# -----------------------------------------------------------------------------
# Fixture-machine constructors (the {hardware} axis).
# -----------------------------------------------------------------------------
def _mac_96gb_unified() -> HostMemoryProfile:
    return HostMemoryProfile(96 * GiB, 0, True, PLATFORM_MACOS)


def _mac_16gb_unified() -> HostMemoryProfile:
    return HostMemoryProfile(16 * GiB, 0, True, PLATFORM_MACOS)


def _ubuntu_64gb_24gb_nvidia() -> HostMemoryProfile:
    return HostMemoryProfile(64 * GiB, 24 * GiB, False, PLATFORM_LINUX)


def _ubuntu_32gb_cpu() -> HostMemoryProfile:
    return HostMemoryProfile(32 * GiB, 0, False, PLATFORM_LINUX)


# -----------------------------------------------------------------------------
# Fixture model variants (the {model} axis).
# -----------------------------------------------------------------------------
def _gpt_oss_120b_mxfp4() -> ModelVariant:
    return ModelVariant(
        String("gpt-oss-120b-MXFP4"),
        String("gpt-oss"),
        62 * GiB,
        String("MXFP4"),
    )


def _llama_70b_q6() -> ModelVariant:
    return ModelVariant(
        String("Llama-3.3-70B-Q6"),
        String("llama-3.3-70b"),
        50 * GiB,
        String("Q6"),
    )


def _llama_70b_q4() -> ModelVariant:
    return ModelVariant(
        String("Llama-3.3-70B-Q4"),
        String("llama-3.3-70b"),
        40 * GiB,
        String("Q4"),
    )


def _qwen_7b_4bit() -> ModelVariant:
    return ModelVariant(
        String("Qwen-7B-4bit"),
        String("qwen-7b"),
        4 * GiB,
        String("4bit"),
    )


# =============================================================================
# (1) Fit-matrix ratings — assert each cell matches the expected rating.
# =============================================================================
def test_fit_matrix_ratings() raises:
    # gpt-oss-120b-MXFP4 (62GB): GREEN only on the 96GB unified Mac; RED on the
    # 16GB Mac, the 24GB-VRAM box, and the 32GB CPU box.
    var gpt = _gpt_oss_120b_mxfp4()
    assert_equal(fit(gpt, _mac_96gb_unified()).rating, FIT_GREEN)
    assert_equal(fit(gpt, _mac_16gb_unified()).rating, FIT_RED)
    assert_equal(fit(gpt, _ubuntu_64gb_24gb_nvidia()).rating, FIT_RED)
    assert_equal(fit(gpt, _ubuntu_32gb_cpu()).rating, FIT_RED)

    # Llama-3.3-70B-Q6 (50GB): GREEN on 96GB unified; RED everywhere else.
    var llama = _llama_70b_q6()
    assert_equal(fit(llama, _mac_96gb_unified()).rating, FIT_GREEN)
    assert_equal(fit(llama, _mac_16gb_unified()).rating, FIT_RED)
    assert_equal(fit(llama, _ubuntu_64gb_24gb_nvidia()).rating, FIT_RED)
    assert_equal(fit(llama, _ubuntu_32gb_cpu()).rating, FIT_RED)

    # Qwen-7B-4bit (4GB): GREEN on every fixture machine (it is tiny).
    var qwen = _qwen_7b_4bit()
    assert_equal(fit(qwen, _mac_96gb_unified()).rating, FIT_GREEN)
    assert_equal(fit(qwen, _mac_16gb_unified()).rating, FIT_GREEN)
    assert_equal(fit(qwen, _ubuntu_64gb_24gb_nvidia()).rating, FIT_GREEN)
    assert_equal(fit(qwen, _ubuntu_32gb_cpu()).rating, FIT_GREEN)


# =============================================================================
# (2) THE NO-FALSE-GREEN PROPERTY — the load-bearing safety invariant. Over the
# whole matrix: a variant whose conservative resident estimate exceeds budget is
# NEVER green, and every GREEN variant's estimate is comfortably below budget.
# =============================================================================
def _all_fixtures() -> List[HostMemoryProfile]:
    var hws = List[HostMemoryProfile]()
    hws.append(_mac_96gb_unified())
    hws.append(_mac_16gb_unified())
    hws.append(_ubuntu_64gb_24gb_nvidia())
    hws.append(_ubuntu_32gb_cpu())
    return hws^


def _all_variants() -> List[ModelVariant]:
    var ms = List[ModelVariant]()
    ms.append(_gpt_oss_120b_mxfp4())
    ms.append(_llama_70b_q6())
    ms.append(_qwen_7b_4bit())
    return ms^


def test_no_false_green_property() raises:
    var hws = _all_fixtures()
    var ms = _all_variants()
    for hi in range(len(hws)):
        for mi in range(len(ms)):
            var r = fit(ms[mi], hws[hi])
            if r.rating == FIT_GREEN:
                # GREEN must NOT overflow the budget — the estimate must fit
                # with the GREEN headroom margin to spare (positive headroom,
                # and resident <= 85% of budget).
                assert_true(
                    r.headroom_bytes > 0,
                    String("GREEN with non-positive headroom: ")
                    + ms[mi].name,
                )
                assert_true(
                    r.resident_bytes * 1000 <= r.budget_bytes * 850,
                    String("GREEN above the 85% band: ") + ms[mi].name,
                )
            elif r.resident_bytes > r.budget_bytes:
                # The conservative estimate exceeds budget -> MUST be RED, never
                # green (a false GREEN) and never yellow (yellow
                # is fits-but-tight, not over-budget).
                assert_equal(
                    r.rating,
                    FIT_RED,
                    String("over-budget variant not RED: ") + ms[mi].name,
                )


# =============================================================================
# (3) THE GPU-VRAM-WALL — discrete-GPU budget is VRAM, not system RAM.
# =============================================================================
def test_discrete_gpu_uses_vram_budget() raises:
    var hw = _ubuntu_64gb_24gb_nvidia()
    assert_true(hw.has_discrete_gpu())
    assert_equal(hw.gpu_budget_bytes(), 24 * GiB)  # VRAM, not 64GB RAM.

    # A 50GB model is RED on this box DESPITE 64GB system RAM, because the GPU
    # serving wall is the 24GB VRAM.
    var r = fit(_llama_70b_q6(), hw)
    assert_equal(r.rating, FIT_RED)
    assert_equal(r.budget_bytes, 24 * GiB)
    # Headroom is the (negative) overshoot past VRAM.
    assert_true(r.headroom_bytes < 0)


def test_unified_uses_total_ram_budget() raises:
    var hw = _mac_96gb_unified()
    assert_false(hw.has_discrete_gpu())  # unified -> no SEPARATE VRAM pool.
    assert_equal(hw.gpu_budget_bytes(), 96 * GiB)  # the unified pool.
    var r = fit(_llama_70b_q6(), hw)
    assert_equal(r.budget_bytes, 96 * GiB)


def test_cpu_only_uses_total_ram_budget() raises:
    var hw = _ubuntu_32gb_cpu()
    assert_false(hw.has_discrete_gpu())
    assert_equal(hw.gpu_budget_bytes(), 0)  # no GPU pool at all.
    # Qwen-7B fits in 32GB system RAM (CPU inference budget).
    var r = fit(_qwen_7b_4bit(), hw)
    assert_equal(r.rating, FIT_GREEN)
    assert_equal(r.budget_bytes, 32 * GiB)


# =============================================================================
# (4) THE YELLOW BAND — fits but tightly. Llama-3.3-70B-Q4 (40 GiB) on a 64 GiB
# unified Mac: 45.2 GiB padded weights + 4 x 2.5 GiB KV + 2 GiB margin = 57.2
# GiB, above the 54.4 GiB GREEN line but within the 64 GiB budget -> YELLOW.
# =============================================================================
def test_yellow_band() raises:
    var hw_64_unified = HostMemoryProfile(64 * GiB, 0, True, PLATFORM_MACOS)
    var r = fit(_llama_70b_q4(), hw_64_unified)
    assert_equal(r.rating, FIT_YELLOW)
    assert_true(r.resident_bytes <= r.budget_bytes)  # fits.
    assert_true(
        r.resident_bytes * 1000 > r.budget_bytes * 850
    )  # but above the GREEN band.
    assert_true(r.headroom_bytes >= 0)  # non-negative (fits) but small.


# =============================================================================
# (5) auto_pick_highest_green_quant — the quant-zoo hide.
# =============================================================================
def _gpt_oss_catalog() -> CatalogEntry:
    """gpt-oss with a 3-quant zoo: MXFP4 (62GB), Q4 (24GB), Q2 (12GB)."""
    var entry = CatalogEntry(String("gpt-oss-120b"), String("gpt-oss"))
    entry.add_variant(
        ModelVariant(
            String("gpt-oss-120b-MXFP4"), String("gpt-oss"), 62 * GiB,
            String("MXFP4"),
        )
    )
    entry.add_variant(
        ModelVariant(
            String("gpt-oss-120b-Q4"), String("gpt-oss"), 24 * GiB,
            String("Q4"),
        )
    )
    entry.add_variant(
        ModelVariant(
            String("gpt-oss-120b-Q2"), String("gpt-oss"), 12 * GiB,
            String("Q2"),
        )
    )
    return entry^


def test_auto_pick_green_first_highest_quality() raises:
    # On a 96GB unified Mac all three quants are GREEN -> pick the HIGHEST
    # quality (MXFP4, the largest weight = best quality), index 0.
    var entry = _gpt_oss_catalog()
    var pick = auto_pick_highest_green_quant(entry, _mac_96gb_unified())
    assert_true(pick.found)
    assert_equal(pick.index, 0)  # MXFP4.
    assert_equal(pick.result.rating, FIT_GREEN)
    assert_true(pick.result.chosen)


def test_auto_pick_picks_best_green_when_top_quant_too_big() raises:
    # On a 32GB unified Mac: MXFP4 and Q4 are RED, Q2 is GREEN -> the policy
    # picks the highest-quality GREEN (Q2, index 2).
    var entry = _gpt_oss_catalog()
    var hw = HostMemoryProfile(32 * GiB, 0, True, PLATFORM_MACOS)
    var pick = auto_pick_highest_green_quant(entry, hw)
    assert_true(pick.found)
    assert_equal(pick.index, 2)  # Q2 — the highest-quality GREEN.
    assert_equal(pick.result.rating, FIT_GREEN)
    assert_true(pick.result.chosen)


def test_auto_pick_falls_back_to_yellow() raises:
    # A machine where the BEST that fits is YELLOW (none GREEN): a 64GB unified
    # box with the Q6 (RED there) and Q4 (YELLOW there, per test (4)) llama
    # variants -> the Q4.
    var entry = CatalogEntry(String("llama-3.3-70b"), String("llama-3.3-70b"))
    entry.add_variant(_llama_70b_q6())  # RED on 64GB unified.
    entry.add_variant(_llama_70b_q4())  # YELLOW on 64GB unified.
    var hw = HostMemoryProfile(64 * GiB, 0, True, PLATFORM_MACOS)
    var pick = auto_pick_highest_green_quant(entry, hw)
    assert_true(pick.found)  # YELLOW counts as "runs".
    assert_equal(pick.index, 1)
    assert_equal(pick.result.rating, FIT_YELLOW)
    assert_true(pick.result.chosen)


def test_auto_pick_not_found_all_red() raises:
    # On a 16GB unified Mac, every gpt-oss quant (including the 12GB Q2, whose
    # conservative resident ~18.9GB exceeds 16GB) is RED -> found=False, and the
    # closest-miss is the smallest quant (Q2, index 2).
    var entry = _gpt_oss_catalog()
    var pick = auto_pick_highest_green_quant(entry, _mac_16gb_unified())
    assert_false(pick.found)
    assert_equal(pick.index, -1)
    # The closest-miss FitResult is the smallest-overshoot RED (Q2).
    assert_equal(pick.result.rating, FIT_RED)
    assert_true(pick.result.headroom_bytes < 0)  # over budget.


# =============================================================================
# (6) HostMemoryProfile pure parse helpers + estimate monotonicity.
# =============================================================================
def test_parse_meminfo() raises:
    var meminfo = String(
        "MemTotal:       65854012 kB\n"
        "MemFree:         1234567 kB\n"
        "MemAvailable:   60000000 kB\n"
    )
    # 65854012 kB.
    assert_equal(_parse_meminfo_total_kb(meminfo), 65854012)


def test_parse_meminfo_missing() raises:
    var meminfo = String("MemFree: 100 kB\nSwapTotal: 0 kB\n")
    assert_equal(_parse_meminfo_total_kb(meminfo), 0)


def test_sum_nvidia_mib() raises:
    # Two GPUs, 24576 MiB each (24GB cards).
    var out = String("24576\n24576\n")
    assert_equal(_sum_nvidia_mib_lines(out), 49152)
    # Empty (no GPUs / nvidia-smi failed) -> 0.
    assert_equal(_sum_nvidia_mib_lines(String("")), 0)
    # A leaked error line is skipped (no positive int parsed).
    assert_equal(
        _sum_nvidia_mib_lines(String("Failed to initialize NVML\n")), 0
    )


def test_first_uint_token() raises:
    assert_equal(_first_uint_token(String("   65854012 kB")), 65854012)
    assert_equal(_first_uint_token(String("nodigits")), 0)
    assert_equal(_first_uint_token(String("42")), 42)


def test_estimate_monotonic_in_weight() raises:
    # A larger quant of the same family must estimate a LARGER resident size
    # (the conservative estimate is monotone in weight bytes).
    var small = ModelVariant(
        String("m-q4"), String("qwen-7b"), 4 * GiB, String("Q4")
    )
    var big = ModelVariant(
        String("m-q8"), String("qwen-7b"), 8 * GiB, String("Q8")
    )
    var es = estimate_resident_bytes(small, DEFAULT_CONTEXT_TOKENS)
    var eb = estimate_resident_bytes(big, DEFAULT_CONTEXT_TOKENS)
    assert_true(eb > es)


def test_estimate_grows_with_context() raises:
    # A longer context costs more KV-cache -> a larger resident estimate.
    var v = _qwen_7b_4bit()
    var short = fit_with_context(v, _mac_96gb_unified(), 2048)
    var long = fit_with_context(v, _mac_96gb_unified(), 32768)
    assert_true(long.resident_bytes > short.resident_bytes)


def test_rating_names() raises:
    assert_equal(fit_rating_name(FIT_GREEN), String("green"))
    assert_equal(fit_rating_name(FIT_YELLOW), String("yellow"))
    assert_equal(fit_rating_name(FIT_RED), String("red"))


# =============================================================================
# (7) Concurrency-aware fit. The KV-cache term scales with the number of
# concurrent streams; a model rated GREEN for 1 chat must reserve MORE KV under
# N concurrent chats (never less), so the resident estimate grows with
# max_concurrent. The weights + OS headroom are per-model (do NOT scale with N).
# =============================================================================
def _embed_variant() -> ModelVariant:
    # bge-small-en-v1.5 class: ~96 MB conservative weight, family "embed".
    return ModelVariant(
        String("bge-small-en-v1.5"),
        String("embed"),
        96 * 1024 * 1024,
        String("bf16"),
    )


def test_kv_scales_with_concurrency() raises:
    # qwen-7b KV is 64 KiB/tok; under N streams the KV budget is N times the
    # single-stream cost.
    var single = kv_cache_bytes(String("qwen-7b"), DEFAULT_CONTEXT_TOKENS)
    var quad = kv_cache_bytes_concurrent(
        String("qwen-7b"), DEFAULT_CONTEXT_TOKENS, 4
    )
    assert_equal(quad, single * 4)
    # max_concurrent of 0 or 1 reduces to the single-stream cost.
    assert_equal(
        kv_cache_bytes_concurrent(String("qwen-7b"), DEFAULT_CONTEXT_TOKENS, 1),
        single,
    )
    assert_equal(
        kv_cache_bytes_concurrent(String("qwen-7b"), DEFAULT_CONTEXT_TOKENS, 0),
        single,
    )


def test_resident_estimate_grows_with_concurrency() raises:
    var v = _qwen_7b_4bit()
    var e1 = estimate_resident_bytes_concurrent(v, DEFAULT_CONTEXT_TOKENS, 1)
    var e4 = estimate_resident_bytes_concurrent(v, DEFAULT_CONTEXT_TOKENS, 4)
    var e8 = estimate_resident_bytes_concurrent(v, DEFAULT_CONTEXT_TOKENS, 8)
    # More concurrency reserves more KV-cache -> a strictly larger estimate.
    assert_true(e4 > e1, String("4-concurrent reserves more than 1"))
    assert_true(e8 > e4, String("8-concurrent reserves more than 4"))
    # The growth is purely the KV term (weights + headroom are per-model): the
    # delta from 1->4 is exactly 3 single-stream KV budgets.
    var kv1 = kv_cache_bytes(String("qwen-7b"), DEFAULT_CONTEXT_TOKENS)
    assert_equal(e4 - e1, kv1 * 3)


def test_default_fit_is_concurrency_aware() raises:
    # The 2-arg estimate_resident_bytes defaults to DEFAULT_MAX_CONCURRENT (the
    # conservative concurrency-aware default), so it equals the explicit
    # DEFAULT_MAX_CONCURRENT estimate.
    var v = _qwen_7b_4bit()
    assert_equal(
        estimate_resident_bytes(v, DEFAULT_CONTEXT_TOKENS),
        estimate_resident_bytes_concurrent(
            v, DEFAULT_CONTEXT_TOKENS, DEFAULT_MAX_CONCURRENT
        ),
    )


def test_concurrency_never_false_greens() raises:
    # Llama-3.3-70B-Q4 (40 GiB) on a 64 GiB unified Mac, where the KV term
    # decides the rating (45.2 GiB padded weights, 2.5 GiB KV per 8k stream,
    # 2 GiB margin, GREEN line 54.4 GiB, budget 64 GiB):
    #   1 stream:   49.7 GiB -> GREEN
    #   4 streams:  57.2 GiB -> YELLOW
    #   16 streams: 87.2 GiB -> RED
    # Each step must strictly lower the rating; a KV term that ignored the
    # stream count would leave all three GREEN.
    var hw = HostMemoryProfile(64 * GiB, 0, True, PLATFORM_MACOS)
    var v = _llama_70b_q4()
    var r1 = fit_concurrent(v, hw, DEFAULT_CONTEXT_TOKENS, 1)
    var r4 = fit_concurrent(v, hw, DEFAULT_CONTEXT_TOKENS, 4)
    var r16 = fit_concurrent(v, hw, DEFAULT_CONTEXT_TOKENS, 16)
    assert_equal(r1.rating, FIT_GREEN)
    assert_equal(r4.rating, FIT_YELLOW)
    assert_equal(r16.rating, FIT_RED)


# =============================================================================
# (7b) GROUND TRUTH — the KV term against the fp16 size computed by hand from
# each family's architecture: 2 (K and V) * layers * KV heads * head dim * 2
# bytes per token. The table may round up, never down.
# =============================================================================
def test_kv_per_token_covers_architecture() raises:
    # llama-3.3-70b: 80 layers, 8 KV heads, head dim 128.
    var llama = 2 * 80 * 8 * 128 * 2
    assert_true(kv_cache_bytes(String("llama-3.3-70b"), 1) >= llama)
    # qwen-7b (Qwen2 / Qwen2.5 7B): 28 layers, 4 KV heads, head dim 128.
    var qwen = 2 * 28 * 4 * 128 * 2
    assert_true(kv_cache_bytes(String("qwen-7b"), 1) >= qwen)
    # gpt-oss-120b: 36 layers, 8 KV heads, head dim 64.
    var gpt = 2 * 36 * 8 * 64 * 2
    assert_true(kv_cache_bytes(String("gpt-oss"), 1) >= gpt)
    # An unknown family is covered up to Llama-2-13B (full multi-head
    # attention: 40 layers, 40 heads, head dim 128).
    var mha13 = 2 * 40 * 40 * 128 * 2
    assert_true(kv_cache_bytes(String("some-other-family"), 1) >= mha13)
    # 8k tokens of llama-3.3-70b KV is 2.5 GiB per stream.
    assert_true(
        kv_cache_bytes(String("llama-3.3-70b"), DEFAULT_CONTEXT_TOKENS)
        >= 5 * GiB // 2
    )


def test_70b_q4_on_64gb_is_not_green() raises:
    # With 4 streams of real KV (4 x 2.5 GiB) on top of the weights, a
    # Llama-3.3-70B-Q4 on a 64 GiB Mac is tight, not comfortable; at a 32k
    # context it does not fit at all.
    var hw = HostMemoryProfile(64 * GiB, 0, True, PLATFORM_MACOS)
    var v = _llama_70b_q4()
    assert_true(fit(v, hw).rating != FIT_GREEN)
    assert_equal(fit_with_context(v, hw, 32768).rating, FIT_RED)


# =============================================================================
# (8) The EMBED family KV=0 calibration row. An embedding model has no
# KV-cache; its per-token KV cost is 0, so its resident estimate is concurrency-
# invariant and its footprint is just weights (without this row the default
# per-token cost would reserve 25 GiB of KV for a ~65 MB model).
# =============================================================================
def test_embed_family_zero_kv() raises:
    # The embed family's KV-cache cost is 0 at any context length / concurrency.
    assert_equal(kv_cache_bytes(String("embed"), DEFAULT_CONTEXT_TOKENS), 0)
    assert_equal(kv_cache_bytes(String("embed"), 32768), 0)
    assert_equal(
        kv_cache_bytes_concurrent(String("embed"), DEFAULT_CONTEXT_TOKENS, 16), 0
    )


def test_embed_footprint_is_weights_only() raises:
    # The embedder's OWN footprint (model_footprint_bytes, no OS headroom) is just
    # its padded weights + 0 KV, with no KV term.
    # bge-small at ~96 MB weight -> footprint well under 200 MB (the embed fudge
    # is 1050 permille = +5%, no 2 GiB headroom in the footprint).
    var v = _embed_variant()
    var footprint = model_footprint_bytes(v, DEFAULT_CONTEXT_TOKENS)
    assert_true(
        footprint < 200 * 1024 * 1024,
        String("embed footprint should be weights-only (<200 MB), got ")
        + String(footprint),
    )
    # And it is concurrency-invariant (no KV to multiply).
    var e1 = estimate_resident_bytes_concurrent(v, DEFAULT_CONTEXT_TOKENS, 1)
    var e16 = estimate_resident_bytes_concurrent(v, DEFAULT_CONTEXT_TOKENS, 16)
    assert_equal(e1, e16)


def test_embed_estimate_is_footprint_plus_headroom() raises:
    # estimate_resident_bytes == model_footprint_bytes + OS_HEADROOM_BYTES. The OS
    # headroom (2 GiB) is the HOST reservation, correctly separable from the
    # model's own footprint (so the multi-model accounting doesn't sum it per
    # model). The embed estimate is dominated by that headroom (footprint ~100 MB).
    var v = _embed_variant()
    assert_equal(
        estimate_resident_bytes(v, DEFAULT_CONTEXT_TOKENS),
        model_footprint_bytes(v, DEFAULT_CONTEXT_TOKENS) + OS_HEADROOM_BYTES,
    )
    # The embedder still rates GREEN on any real host (it fits trivially).
    assert_equal(fit(v, _mac_16gb_unified()).rating, FIT_GREEN)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
