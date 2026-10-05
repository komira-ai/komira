# =============================================================================
# komira_localmodel/fit_resolver.mojo
#   The pure "will it run" signal: before a multi-GB download and a
#   multi-second model load, say whether a model variant will run on THIS
#   machine comfortably (green), run but tightly (yellow), or spill / OOM
#   (red), and pick the highest-quality quantization that lands GREEN.
# =============================================================================
#
# CONSERVATIVE BIAS: a FALSE GREEN is the failure this signal exists to
# prevent. A caller told "green" that then hits a swap storm or an OOM in the
# middle of inference is worse off than one told "yellow". So the resident
# estimate is biased to OVER-estimate: it rounds UP, applies a per-model-family
# fudge factor >= 1.0, and the GREEN band leaves a headroom margin. The
# property the unit tests pin: a model that would SPILL is RED or YELLOW, never
# GREEN.
#
# RESIDENT-SIZE ESTIMATE (not a first-principles formula):
#   estimate = ceil(weight_bytes * family_fudge)
#            + kv_cache_bytes(ctx_tokens, family) * concurrent_streams
#            + OS_HEADROOM_BYTES
# The `family_fudge` and the per-token KV-cache cost are a TABLE keyed by model
# family. The KV row is the fp16 size from the family's architecture (layers,
# KV heads, head dimension), rounded up; the weight fudge is a conservative
# first cut, uncalibrated against measured RSS. Lowering a value toward
# measured truth needs care, raising one is always safe. See the calibration
# note at the bottom of this file.
#
# QUANTIZATION CHOICE: a CatalogEntry holds N quantizations of one model (e.g.
# gpt-oss-120b at MXFP4 / Q8 / Q6 / Q4). `auto_pick_highest_green_quant` takes
# the highest-quality one that fits GREEN, falls back to the best YELLOW if
# nothing fits GREEN, and reports the closest RED miss if nothing fits at all,
# so a caller can ask for "gpt-oss-120b" and get the best quantization this
# machine can serve.
#
# PURE: no I/O, no process spawn. Every function here is a pure function of
# (ModelVariant / CatalogEntry, HostMemoryProfile); the unit tests drive a
# {hardware} x {model variant} matrix and assert the ratings and the chosen
# quantization, including the no-false-GREEN property. No pointers.
# =============================================================================

from .host_profile import HostMemoryProfile


# -----------------------------------------------------------------------------
# Fit rating — a small POD enum.
#   GREEN  — fits comfortably (resident estimate <= budget * GREEN_FRACTION).
#   YELLOW — fits but tightly (resident estimate <= budget, but above the GREEN
#            band) — runnable, but with little headroom for other processes /
#            a longer context, which a caller should surface.
#   RED    — does not fit (resident estimate > budget) — would spill / OOM.
# -----------------------------------------------------------------------------
comptime FIT_RED: Int = 0
comptime FIT_YELLOW: Int = 1
comptime FIT_GREEN: Int = 2

# Type alias for readability at call sites (the rating is an Int code).
comptime FitRating = Int


def fit_rating_name(rating: Int) -> StaticString:
    if rating == FIT_GREEN:
        return "green"
    elif rating == FIT_YELLOW:
        return "yellow"
    return "red"


# -----------------------------------------------------------------------------
# Estimate-tuning constants (the CONSERVATIVE first-cut calibration table).
#
# These bias the estimate UP. The whole table is the calibratable seam — see
# the calibration note at the bottom of the file. All values err on the side of
# over-estimation (a false GREEN is the failure to avoid).
# -----------------------------------------------------------------------------

# The default context window the KV-cache budget is sized for. A model serving
# longer contexts costs more KV-cache; 8192 is a conservative default-serving
# context (most local-serving defaults are 2k-8k; we size for the upper end).
comptime DEFAULT_CONTEXT_TOKENS: Int = 8192

# OS / runtime headroom margin: bytes reserved for the OS, the serving runtime's
# own footprint (the python / llama-server process, CUDA / Metal driver buffers,
# the HTTP server), and general slack. 2 GiB is a deliberately generous margin —
# the cost of reserving too much is a YELLOW where GREEN might have been safe
# (acceptable); the cost of reserving too little is a false-GREEN (unacceptable).
comptime OS_HEADROOM_BYTES: Int = 2 * 1024 * 1024 * 1024

# The GREEN band: a variant is GREEN only when its resident estimate is at most
# this fraction of the budget — i.e. GREEN demands ~15% spare budget on top of
# the already-conservative estimate. Expressed as a permille (out of 1000) to
# avoid float in the comparison. 850 => the estimate must be <= 85% of budget.
comptime GREEN_BUDGET_PERMILLE: Int = 850

# Default per-family weight fudge factor (permille, out of 1000) when a family
# is not in the explicit table below. 1150 => assume real resident weights are
# ~15% above the on-disk weight byte count (loader overhead, alignment padding,
# non-quantized layers like embeddings/norms kept in higher precision).
comptime DEFAULT_WEIGHT_FUDGE_PERMILLE: Int = 1150

# KV-cache cost PER TOKEN (bytes) for a family with no row in
# `_kv_bytes_per_token`: 2 (K and V) * layers * kv_heads * head_dim * 2 bytes
# (fp16) for the largest common architecture up to 70B, Llama-2-13B with full
# multi-head attention (2 * 40 * 40 * 128 * 2 = 819,200 = 800 KiB). It covers
# the full-attention 7B models and the grouped-query 70B models; a family
# larger than that needs its own row.
comptime DEFAULT_KV_BYTES_PER_TOKEN: Int = 800 * 1024

# -----------------------------------------------------------------------------
# CONCURRENCY (the concurrency-aware fit). The KV-cache term sizes ONE
# stream's context. Under N concurrent requests against ONE loaded model the
# engine holds N separate KV-cache contexts (continuous batching allocates
# per-sequence KV), so the resident KV-cache cost scales ~linearly with the
# number of concurrent streams. A fit that is GREEN for 1 chat can SPILL under N
# concurrent chats, which is the silent memory wall this module guards against.
# So `estimate_resident_bytes` multiplies the KV term by a max-concurrent factor.
#
# THE DEFAULT (conservative bias): Ollama's OLLAMA_NUM_PARALLEL defaults to 1 (or
# 4 with spare memory); the default here is 4 concurrent streams, so the fit
# budget reserves KV cache for a multi-chat load up front rather than
# discovering the wall at request N. Admission control caps at the same number
# (the cap is derived from it), so the fit signal and the admission cap agree.
# A caller passes its own count to the `*_concurrent` functions. Larger => more
# KV reserved => fewer models rate GREEN (the safe direction). An EMBEDDER (KV=0) is unaffected (its
# KV term is 0 regardless of concurrency — embeddings are single-pass, no
# autoregressive context).
comptime DEFAULT_MAX_CONCURRENT: Int = 4


# -----------------------------------------------------------------------------
# ModelVariant — one specific quantization of a model. The unit of a fit query.
# -----------------------------------------------------------------------------
struct ModelVariant(Copyable, ImplicitlyCopyable, Movable, Writable):
    """A specific quantization of a model.

    Fields:
      * name         — the variant's display name (e.g. "gpt-oss-120b-MXFP4").
      * family       — the model family key for the calibration table (e.g.
                       "gpt-oss", "llama-3.3-70b", "qwen-7b"). Drives the fudge
                       factor + KV-cache cost lookup. Lowercased by convention.
      * weight_bytes — the on-disk quantized weight byte count (the dominant
                       resident-size term).
      * quant_label  — a human label for the quantization (e.g. "MXFP4", "Q6",
                       "4bit"). Informational; the fit math uses weight_bytes.
      * quality_rank — a monotone "higher is better quality" ordering key used
                       by auto_pick_highest_green_quant. By convention this is
                       just `weight_bytes` (more bits retained = better quality),
                       but kept as an explicit field so a catalog can override
                       (e.g. an MXFP4 variant that beats a same-size Q4).
    """

    var name: String
    var family: String
    var weight_bytes: Int
    var quant_label: String
    var quality_rank: Int

    def __init__(
        out self,
        name: String,
        family: String,
        weight_bytes: Int,
        quant_label: String,
    ):
        """quality_rank defaults to weight_bytes (more bits = better quality)."""
        self.name = name
        self.family = family
        self.weight_bytes = weight_bytes
        self.quant_label = quant_label
        self.quality_rank = weight_bytes

    def __init__(
        out self,
        name: String,
        family: String,
        weight_bytes: Int,
        quant_label: String,
        quality_rank: Int,
    ):
        """Explicit quality_rank (override the weight-bytes default)."""
        self.name = name
        self.family = family
        self.weight_bytes = weight_bytes
        self.quant_label = quant_label
        self.quality_rank = quality_rank

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "ModelVariant(",
            self.name,
            ", family=",
            self.family,
            ", weight=",
            self.weight_bytes,
            "B, quant=",
            self.quant_label,
            ")",
        )


# -----------------------------------------------------------------------------
# CatalogEntry — a model with all its quantizations. "Run model X" maps to a
# CatalogEntry; auto_pick_highest_green_quant makes the variant choice.
# -----------------------------------------------------------------------------
struct CatalogEntry(Movable):
    """A model and its available quantization variants.

    `auto_pick_highest_green_quant(entry, hw)` is the policy that turns
    "run model X" into a concrete variant the machine can serve GREEN.
    """

    var model_name: String
    var family: String
    var variants: List[ModelVariant]

    def __init__(out self, model_name: String, family: String):
        self.model_name = model_name
        self.family = family
        self.variants = List[ModelVariant]()

    def add_variant(mut self, var variant: ModelVariant):
        self.variants.append(variant^)


# -----------------------------------------------------------------------------
# FitResult — the answer to a fit query.
# -----------------------------------------------------------------------------
struct FitResult(Copyable, ImplicitlyCopyable, Movable, Writable):
    """The "will-it-run" answer for one (variant, hardware) pair.

    Fields:
      * rating         — FIT_GREEN / FIT_YELLOW / FIT_RED.
      * headroom_bytes — budget - resident_estimate. POSITIVE = spare budget;
                         NEGATIVE = the overshoot (how far over budget the
                         estimate is). Signed Int.
      * chosen         — whether this variant was the one auto_pick selected
                         (False from a bare `fit()` call; set True on the picked
                         variant by auto_pick_highest_green_quant).
      * resident_bytes — the conservative resident-size estimate used.
      * budget_bytes   — the memory budget the estimate was compared against.
    """

    var rating: Int
    var headroom_bytes: Int
    var chosen: Bool
    var resident_bytes: Int
    var budget_bytes: Int

    def __init__(
        out self,
        rating: Int,
        headroom_bytes: Int,
        chosen: Bool,
        resident_bytes: Int,
        budget_bytes: Int,
    ):
        self.rating = rating
        self.headroom_bytes = headroom_bytes
        self.chosen = chosen
        self.resident_bytes = resident_bytes
        self.budget_bytes = budget_bytes

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "FitResult(",
            fit_rating_name(self.rating),
            ", headroom=",
            self.headroom_bytes,
            "B, resident=",
            self.resident_bytes,
            "B, budget=",
            self.budget_bytes,
            "B, chosen=",
            self.chosen,
            ")",
        )


# =============================================================================
# The calibration table (PURE family-keyed lookups). The whole purpose of
# routing the fudge / KV-cost through these helpers (rather than inlining
# constants) is to make the calibration seam explicit and easy to tune.
# =============================================================================


def _weight_fudge_permille(family: String) -> Int:
    """Per-family weight fudge factor (permille). >= 1000 (never under-count).

    CONSERVATIVE first cut. Tuning DOWN toward measured RSS is the safe
    direction. The MXFP4 / FP4 ultra-low-bit families carry slightly more
    overhead (the non-quantized layers dominate a larger share), so a touch
    higher; the well-trodden GGUF Q-quants are closer to their on-disk size.
    """
    if family == "gpt-oss":
        # MXFP4-heavy; non-quantized embeddings/norms are a larger relative
        # share for these very large models.
        return 1200
    elif family == "llama-3.3-70b":
        return 1130
    elif family == "qwen-7b":
        return 1120
    elif family == "embed":
        # A small bf16/fp16 embedding model (bge-small / nomic / e5 class). The
        # weights load nearly 1:1 (no quant overhead, the model is tiny); a
        # modest 1050 covers the runtime/loader slack. The big over-count for the
        # embedder was the KV term (see _kv_bytes_per_token), not the weights.
        # Uncalibrated: the assumption is loader overhead ~= 5% of a ~65 MB
        # weight set (bge-small-en-v1.5 class).
        return 1050
    return DEFAULT_WEIGHT_FUDGE_PERMILLE


def _kv_bytes_per_token(family: String) -> Int:
    """Per-family KV-cache cost per token (bytes), at fp16.

    One token keeps a key and a value vector per layer per KV head:
    2 (K and V) * layers * kv_heads * head_dim * 2 bytes. The rows use the
    published architecture of each family and round up:
      * gpt-oss-120b: 36 layers, 8 KV heads, head dim 64 -> 73,728; the row
        is 80 KiB. (Half its layers use a 128-token sliding window, so this
        full-attention figure over-counts.)
      * llama-3.3-70b: 80 layers, 8 KV heads, head dim 128 -> 327,680
        (320 KiB).
      * qwen-7b (the Qwen2 / Qwen2.5 7B architecture): 28 layers, 4 KV heads,
        head dim 128 -> 57,344; the row is 64 KiB.
    An engine that quantizes its KV cache uses less; none uses more.
    """
    if family == "gpt-oss":
        return 80 * 1024
    elif family == "llama-3.3-70b":
        return 320 * 1024
    elif family == "qwen-7b":
        return 64 * 1024
    elif family == "embed":
        # An EMBEDDING model has NO KV-cache: there is no autoregressive decode,
        # no per-token attention state to retain — an embed request is a single
        # forward pass that emits one vector and keeps nothing. So the per-token
        # KV cost is ZERO, and the embedder's estimate is concurrency-invariant.
        return 0
    return DEFAULT_KV_BYTES_PER_TOKEN


def kv_cache_bytes(family: String, context_tokens: Int) -> Int:
    """The KV-cache budget for ONE stream of `context_tokens` for `family`.

    Linear in context length at the family's per-token cost. The PURE seam the
    estimate uses; exposed so a test / a config can size for a non-default
    context. For the CONCURRENT KV budget (N streams) see
    `kv_cache_bytes_concurrent`."""
    var per_tok = _kv_bytes_per_token(family)
    var toks = context_tokens if context_tokens > 0 else DEFAULT_CONTEXT_TOKENS
    return per_tok * toks


def kv_cache_bytes_concurrent(
    family: String, context_tokens: Int, max_concurrent: Int
) -> Int:
    """The KV-cache budget for `max_concurrent` concurrent streams of
    `context_tokens` for `family` (the concurrency-aware KV term).

    Under N concurrent requests against one loaded model the engine holds N
    independent KV-cache contexts (continuous batching allocates per-sequence
    KV), so the resident KV cost is N times the single-stream cost. A
    `max_concurrent` of 0 or 1 reduces to the single-stream `kv_cache_bytes`. An
    EMBEDDER (family "embed", per-token KV = 0) yields 0 regardless of N (no
    autoregressive context to multiply). PURE."""
    var n = max_concurrent if max_concurrent > 0 else 1
    return kv_cache_bytes(family, context_tokens) * n


def _ceil_mul_permille(value: Int, permille: Int) -> Int:
    """Ceil(value * permille / 1000) in pure integer math (rounds UP — the
    conservative direction). permille is the fudge factor out of 1000."""
    var num = value * permille
    # Ceiling division by 1000.
    return (num + 999) // 1000


# =============================================================================
# The resident-size estimate + the fit decision.
# =============================================================================


def estimate_resident_bytes(variant: ModelVariant, context_tokens: Int) -> Int:
    """The CONSERVATIVE resident-size estimate for serving `variant` at the
    default concurrency (DEFAULT_MAX_CONCURRENT streams).

    This 2-arg form is the concurrency-AWARE default: it reserves KV-cache for a
    realistic multi-chat load (DEFAULT_MAX_CONCURRENT) so a fit that rates GREEN
    does not silently spill under concurrency. For an explicit concurrency, use
    `estimate_resident_bytes_concurrent`. PURE."""
    return estimate_resident_bytes_concurrent(
        variant, context_tokens, DEFAULT_MAX_CONCURRENT
    )


def estimate_resident_bytes_concurrent(
    variant: ModelVariant, context_tokens: Int, max_concurrent: Int
) -> Int:
    """The CONSERVATIVE resident-size estimate for serving `variant` under
    `max_concurrent` concurrent streams (concurrency-aware).

    estimate = ceil(weight_bytes * family_fudge)                 (weights, padded)
             + kv_cache_bytes_concurrent(family, ctx, N)         (N-stream KV)
             + OS_HEADROOM_BYTES                                 (OS + runtime)

    The weights + OS headroom are a per-MODEL cost (shared across streams); only
    the KV-cache scales with the concurrency N (each concurrent stream holds its
    own KV context). Every term rounds UP / over-estimates. NOT a first-
    principles formula: the fudge + KV cost are a family-keyed table, not yet
    calibrated against measured RSS. An EMBEDDER (KV=0) is
    concurrency-invariant. PURE.
    """
    return (
        model_footprint_bytes_concurrent(variant, context_tokens, max_concurrent)
        + OS_HEADROOM_BYTES
    )


def model_footprint_bytes(variant: ModelVariant, context_tokens: Int) -> Int:
    """The model's OWN resident footprint (padded weights + its single-stream
    KV-cache) WITHOUT the OS/runtime headroom margin.

    `estimate_resident_bytes` = `model_footprint_bytes` + OS_HEADROOM_BYTES. The
    OS headroom is a HOST-level reservation (the OS + the serving runtime's own
    footprint + general slack), NOT a per-model cost — so for the per-model
    figure (`/models` resident_bytes) and for the SM's multi-model eviction
    accounting (summing N resident models), the footprint is the honest per-model
    figure (summing the 2 GiB OS headroom once per model would triple-count it
    when 3 models are resident). The fit RATING still uses the full estimate (a
    single model competes against the whole budget WITH the OS headroom reserved
    — that is the correct conservative fit comparison). PURE."""
    return model_footprint_bytes_concurrent(
        variant, context_tokens, DEFAULT_MAX_CONCURRENT
    )


def model_footprint_bytes_concurrent(
    variant: ModelVariant, context_tokens: Int, max_concurrent: Int
) -> Int:
    """`model_footprint_bytes` under `max_concurrent` concurrent streams (only the
    KV term scales with N; the weights are shared). PURE."""
    var padded_weights = _ceil_mul_permille(
        variant.weight_bytes, _weight_fudge_permille(variant.family)
    )
    var kv = kv_cache_bytes_concurrent(
        variant.family, context_tokens, max_concurrent
    )
    return padded_weights + kv


def _budget_bytes(hw: HostMemoryProfile) -> Int:
    """The memory budget a model may occupy on `hw`.

    Unified silicon (Apple): the GPU shares system RAM, so the budget is total
    RAM (the model + KV-cache live in the one unified pool).
    Discrete GPU (Linux + NVIDIA): a GPU-served model is bounded by VRAM — that
    is the hard wall a too-big model hits. We use VRAM as the budget when a
    discrete GPU is present (the conservative wall for GPU serving).
    CPU-only (no VRAM, not unified): the budget is total RAM (CPU inference
    holds weights + KV-cache in system RAM).
    """
    if hw.unified_memory:
        return hw.total_ram_bytes
    if hw.has_discrete_gpu():
        return hw.vram_bytes
    return hw.total_ram_bytes


def fit(variant: ModelVariant, hw: HostMemoryProfile) -> FitResult:
    """The "will-it-run" signal for `variant` on `hw` at the default context.

    Compares the CONSERVATIVE resident estimate against the machine's memory
    budget:
      * GREEN  — estimate <= budget * GREEN_BUDGET_PERMILLE/1000 (fits with the
                 GREEN headroom margin to spare).
      * YELLOW — estimate <= budget, but above the GREEN band (fits, tight).
      * RED    — estimate > budget (would spill / OOM).
    `chosen` is False (a bare fit query); auto_pick sets it on the picked
    variant. The no-false-GREEN property: because the estimate over-counts and
    GREEN demands a margin below budget, a variant that would actually spill
    lands RED (or at worst YELLOW), never GREEN.
    """
    return fit_with_context(variant, hw, DEFAULT_CONTEXT_TOKENS)


def fit_with_context(
    variant: ModelVariant, hw: HostMemoryProfile, context_tokens: Int
) -> FitResult:
    """`fit` for an explicit context length (the KV-cache scales with it), at the
    default concurrency (DEFAULT_MAX_CONCURRENT)."""
    return fit_concurrent(
        variant, hw, context_tokens, DEFAULT_MAX_CONCURRENT
    )


def fit_concurrent(
    variant: ModelVariant,
    hw: HostMemoryProfile,
    context_tokens: Int,
    max_concurrent: Int,
) -> FitResult:
    """The concurrency-aware "will-it-run" signal. Reserves KV-cache for
    `max_concurrent` concurrent streams (the N-chat load) before rating, so a
    GREEN here means the model fits at that concurrency, not just for one chat.
    `max_concurrent` of 0/1 reduces to the single-stream fit. PURE."""
    var resident = estimate_resident_bytes_concurrent(
        variant, context_tokens, max_concurrent
    )
    var budget = _budget_bytes(hw)
    var headroom = budget - resident
    # GREEN threshold: estimate must sit at or below GREEN_BUDGET_PERMILLE/1000
    # of the budget. Integer comparison: estimate*1000 <= budget*permille.
    var green_ok = resident * 1000 <= budget * GREEN_BUDGET_PERMILLE
    var fits_at_all = resident <= budget
    var rating: Int
    if green_ok:
        rating = FIT_GREEN
    elif fits_at_all:
        rating = FIT_YELLOW
    else:
        rating = FIT_RED
    return FitResult(
        rating=rating,
        headroom_bytes=headroom,
        chosen=False,
        resident_bytes=resident,
        budget_bytes=budget,
    )


# =============================================================================
# Quantization choice: auto-pick the highest-quality GREEN variant.
# =============================================================================


struct AutoPick(Movable):
    """The result of auto_pick_highest_green_quant.

    Fields:
      * found  — True iff at least one variant fits AT ALL (GREEN or YELLOW). If
                 False, NOTHING in the catalog runs on this machine (all RED) —
                 `index` is -1 and `result` carries the best (least-overshoot)
                 RED variant's FitResult for the "closest miss" message.
      * index  — the index of the picked variant within `entry.variants`
                 (-1 when not found).
      * result — the picked variant's FitResult (with chosen=True when found).
    """

    var found: Bool
    var index: Int
    var result: FitResult

    def __init__(out self, found: Bool, index: Int, result: FitResult):
        self.found = found
        self.index = index
        self.result = result


def auto_pick_highest_green_quant(
    entry: CatalogEntry, hw: HostMemoryProfile
) -> AutoPick:
    """Pick the highest-QUALITY variant that fits, GREEN-first.

    Policy:
      1. Among the variants that fit GREEN, pick the highest quality_rank (best
         quality the machine can serve comfortably).
      2. If NONE fit GREEN, among the variants that fit YELLOW, pick the highest
         quality_rank (the best quality that at least runs, tightly).
      3. If NONE fit at all (all RED), report not-found + the closest-miss
         variant (the one with the smallest overshoot) so the caller can tell
         the caller how far over budget the smallest quant was.

    Returns an AutoPick. When found, `result.chosen` is True. PURE.
    """
    var best_green_idx = -1
    var best_green_rank = -1
    var best_yellow_idx = -1
    var best_yellow_rank = -1
    var closest_red_idx = -1
    var closest_red_overshoot = 0  # most-positive overshoot tracking
    var closest_red_result = FitResult(FIT_RED, 0, False, 0, 0)

    for i in range(len(entry.variants)):
        var r = fit(entry.variants[i], hw)
        if r.rating == FIT_GREEN:
            if entry.variants[i].quality_rank > best_green_rank:
                best_green_rank = entry.variants[i].quality_rank
                best_green_idx = i
        elif r.rating == FIT_YELLOW:
            if entry.variants[i].quality_rank > best_yellow_rank:
                best_yellow_rank = entry.variants[i].quality_rank
                best_yellow_idx = i
        else:
            # RED — track the closest miss (smallest overshoot = headroom
            # closest to zero from below, i.e. the largest headroom_bytes which
            # is negative for RED).
            var overshoot = -r.headroom_bytes  # positive bytes over budget
            if closest_red_idx < 0 or overshoot < closest_red_overshoot:
                closest_red_overshoot = overshoot
                closest_red_idx = i
                closest_red_result = r

    if best_green_idx >= 0:
        var r = fit(entry.variants[best_green_idx], hw)
        return AutoPick(
            found=True,
            index=best_green_idx,
            result=FitResult(
                r.rating, r.headroom_bytes, True, r.resident_bytes,
                r.budget_bytes,
            ),
        )
    if best_yellow_idx >= 0:
        var r = fit(entry.variants[best_yellow_idx], hw)
        return AutoPick(
            found=True,
            index=best_yellow_idx,
            result=FitResult(
                r.rating, r.headroom_bytes, True, r.resident_bytes,
                r.budget_bytes,
            ),
        )
    # Nothing fits — return the closest-miss RED for a helpful message.
    return AutoPick(found=False, index=-1, result=closest_red_result)


# =============================================================================
# CALIBRATION NOTE
# =============================================================================
#
# The resident-size estimate is the main accuracy unknown in this module. The
# per-token KV-cache costs (`_kv_bytes_per_token`) are the fp16 sizes from each
# family's architecture, rounded up; the weight fudge factors
# (`_weight_fudge_permille`) are a CONSERVATIVE first cut, not measured, and
# will be wrong in detail.
#
# How to calibrate it:
#   1. Serve each catalog variant, warm-load it, run a representative inference
#      at the default context, and measure the RSS (and GPU memory via
#      nvidia-smi / Metal).
#   2. Compare the measurement with estimate_resident_bytes(). The estimate MUST
#      be >= the measurement (the conservative invariant). An under-count is a
#      calibration bug: raise that family's fudge.
#   3. Lower table values toward (but staying above) the measurements so GREEN
#      is not needlessly conservative. Lowering is the only direction that needs
#      care; raising is always safe.
#   4. Consider moving the table to a data file (one row per family) so a
#      calibration run can update it without a recompile.
#
# Until then the bias is intentional and the failure mode is benign: a variant
# rated YELLOW that would have been GREEN, never a variant rated GREEN that
# spills.
#
# Two further uncalibrated assumptions:
#   * CONCURRENCY (DEFAULT_MAX_CONCURRENT = 4): the KV term is multiplied by the
#     concurrent-stream count, so the default fit reserves KV for 4 streams.
#     To check: measure engine RSS at 1, 2, 4 and 8 concurrent decodes of a
#     7B 4-bit model; the per-stream KV cost should be about linear and the
#     per-token table should over-estimate it. mlx-lm reports KV cross-
#     contamination at 16+ concurrent prompts (ml-explore/mlx-lm#965), which is
#     why admission control caps concurrency at this same N.
#   * EMBED FAMILY (KV per token = 0, weight fudge 1050): an embedding model has
#     no KV cache. To check: measure the RSS of a bge-small-en-v1.5 server; the
#     1050 fudge assumes ~5% loader slack on a ~65 MB weight set. The 2 GiB
#     OS_HEADROOM still dominates the embedder's fit estimate (its own footprint
#     is ~100 MB); that headroom is a HOST reservation and is not summed per
#     model in the multi-model accounting (see model_footprint_bytes).
