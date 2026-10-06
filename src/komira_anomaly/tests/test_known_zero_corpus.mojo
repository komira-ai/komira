# =============================================================================
# tests/test_known_zero_corpus.mojo
#   ⭐ THE FALSIFIER THAT USES REAL RECORDED MEASUREMENTS, NOT SYNTHETIC ONES.
#
# ── WHAT THE DATA IS ─────────────────────────────────────────────────────────
#
# Ten complete sweeps of a SQL benchmark corpus, run on one machine in one
# afternoon and recorded as JSONL. THERE WAS
# NO CODE CHANGE BETWEEN THEM. That makes this a KNOWN ZERO: every change point
# a detector reports on this data is, by construction, a false one — no
# statistical argument is needed to say so, because the thing that would have
# caused a true one did not happen.
#
# A known zero is the only honest way to calibrate a detector before real
# history exists. Synthetic noise proves a detector works on the noise the
# author imagined; this data is the noise the machine actually has.
#
# ── EXTRACTION, STATED SO IT CAN BE CHECKED ─────────────────────────────────
#
#   source   ten sweep files, one JSON row per cell
#   field    the engine's own median wall in ms, not the ratio against a
#            reference engine. This series is the one to watch because the
#            ratio's denominator is ~2.9x noisier than the engine's own wall,
#            so a detector on the ratio mostly watches the reference re-draw.
#   filter   rows whose execution stage is OK, present in ALL TEN sweeps.
#   result   82 cells. (84 entries are attempted; the two `c5*_inner_join_
#            varchar` cells fail to execute and are absent from every sweep.)
#
# The extraction's summary statistics -- median spread 5.03%, 14 of 82 cells
# spreading more than 10%, max 22.17% -- are a check that these are the
# recorded numbers.
#
# ⚠ THESE ROWS ARE NOT, AND MUST NOT BECOME, A MEASUREMENT STORE. They carry no
# host, no commit sha, no runner identity and no gate vector, because the
# recorded rows do not carry them either. They are admissible HERE, as a
# calibration constant with its provenance written down, and they would be
# inadmissible as series points in any store that requires a row to state which
# binary produced it.
#
# ── WHAT THIS FILE ASSERTS ───────────────────────────────────────────────────
#
#   (1) FALSE POSITIVES. At the corpus-wide budget the detector fires on AT
#       MOST ONE of the 82 cells. Measured: it fires on ZERO.
#   (2) THE BUDGET IS NOT FREE. At the naive alpha = 0.05 the SAME detector on
#       the SAME data fires on more than one cell -- so (1) is a property of
#       the significance level being a corpus-wide budget, not a property of
#       the method being magic. Without this arm, (1) could be passed by a
#       detector that is simply deaf.
#   (3) POWER. The detector is NOT deaf: with five post-change points, a real
#       shift is found on the large majority of the same 82 cells.
#   (4) THE FIXED THRESHOLD FAILS THE SAME TEST. A fixed 1.10x-versus-baseline
#       threshold -- the usual regression-check rule --
#       fires repeatedly on this zero-change data. Asserted here so the claim
#       is a measurement in a test rather than a sentence in a design doc.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_anomaly import (
    DEFAULT_SIGNIFICANCE,
    DetectorConfig,
    STATE_ANOMALY,
    STATE_NORMAL,
    Series,
    SeriesDetector,
    median_of,
)


struct Cell(Copyable, Movable, Deinitable):
    var key: String
    var values: List[Float64]

    def __init__(out self, key: String, var values: List[Float64]):
        self.key = key
        self.values = values^


def _cell(mut out: List[Cell], key: String, var values: List[Float64]):
    out.append(Cell(key, values^))


def known_zero_corpus() -> List[Cell]:
    """82 cells x 10 sweeps of ONE binary. See the file header for provenance.
    """
    var out = List[Cell]()
    _cell(out, String("clickbench/cb01_count"), [0.097, 0.098, 0.107, 0.098, 0.098, 0.102, 0.097, 0.097, 0.098, 0.104])
    _cell(out, String("clickbench/cb02_filter_count"), [7.012, 7.107, 7.056, 7.156, 7.121, 7.206, 6.918, 7.109, 6.972, 7.077])
    _cell(out, String("clickbench/cb03_date_filter"), [33.299, 34.009, 33.143, 33.12, 33.652, 33.45, 34.224, 33.241, 33.946, 33.428])
    _cell(out, String("clickbench/cb04_count_distinct"), [168.75, 165.191, 168.186, 168.467, 167.939, 166.832, 166.838, 165.948, 166.292, 164.745])
    _cell(out, String("clickbench/cb05_filter_distinct"), [173.101, 171.392, 173.297, 172.636, 169.282, 171.267, 171.649, 170.754, 169.081, 171.611])
    _cell(out, String("clickbench/cb06_min_max"), [14.133, 14.105, 16.56, 16.583, 14.132, 14.147, 14.082, 14.119, 14.143, 14.174])
    _cell(out, String("clickbench/cb07_topn_regions"), [60.189, 60.148, 59.485, 61.258, 62.177, 60.545, 60.01, 59.983, 60.038, 59.998])
    _cell(out, String("clickbench/cb08_region_refresh"), [182.517, 182.653, 182.91, 184.698, 183.504, 182.696, 182.041, 182.399, 182.719, 182.257])
    _cell(out, String("clickbench/cb09_counter_avg_width"), [213.068, 207.018, 215.612, 207.472, 209.548, 213.008, 211.357, 209.018, 210.566, 212.238])
    _cell(out, String("clickbench/cb10_os_users"), [489.505, 488.101, 487.004, 488.073, 496.584, 495.38, 482.737, 486.191, 491.034, 483.647])
    _cell(out, String("clickbench/cb11_age_groupby"), [39.886, 39.937, 40.009, 39.757, 40.063, 41.393, 40.048, 39.879, 40.25, 39.794])
    _cell(out, String("clickbench/cb12_age_sex_groupby"), [101.791, 102.17, 102.998, 101.746, 102.405, 103.371, 102.177, 101.89, 102.193, 102.845])
    _cell(out, String("clickbench/cb13_counter_distinct_users"), [411.23, 423.518, 412.221, 406.013, 413.198, 412.549, 410.111, 409.589, 420.484, 408.846])
    _cell(out, String("clickbench/cb14_is_refresh_groupby"), [36.948, 37.067, 36.899, 37.726, 37.157, 38.358, 37.063, 37.321, 37.245, 37.745])
    _cell(out, String("clickbench/cb15_date_groupby"), [33.992, 34.162, 34.091, 34.997, 34.451, 35.228, 34.239, 34.202, 34.277, 34.12])
    _cell(out, String("clickbench/cb16_region_avg_age_having"), [245.33, 245.966, 245.852, 246.833, 246.744, 247.091, 244.815, 247.458, 245.759, 245.363])
    _cell(out, String("clickbench/cb17_counter_region_groupby"), [256.137, 256.776, 256.362, 257.928, 255.569, 259.325, 255.809, 258.55, 254.964, 256.495])
    _cell(out, String("clickbench/cb18_resolution_filter_groupby"), [139.097, 139.597, 139.229, 140.135, 139.247, 139.811, 139.054, 140.455, 139.684, 138.899])
    _cell(out, String("clickbench/cb19_sex_multi_agg"), [249.006, 239.279, 246.999, 248.93, 253.17, 242.439, 242.415, 250.141, 249.684, 254.313])
    _cell(out, String("clickbench/cb20_semi_join"), [416.061, 414.391, 416.033, 417.309, 412.778, 416.084, 423.52, 414.536, 413.414, 416.417])
    _cell(out, String("h2o/j1_join_small"), [69.195, 67.203, 70.17, 70.393, 71.397, 71.219, 69.963, 70.313, 70.697, 70.444])
    _cell(out, String("h2o/j2_join_medium"), [83.433, 81.49, 83.679, 82.248, 85.316, 82.169, 82.36, 83.395, 84.286, 83.369])
    _cell(out, String("h2o/j3_join_medium_int"), [83.416, 84.648, 83.391, 82.868, 86.071, 83.476, 84.187, 83.723, 84.875, 83.861])
    _cell(out, String("h2o/j4_join_big"), [44.375, 44.079, 44.627, 44.388, 45.519, 43.909, 45.202, 44.524, 46.303, 45.126])
    _cell(out, String("h2o/j5_join_2key"), [109.384, 107.762, 107.144, 106.216, 111.364, 110.367, 106.648, 108.005, 115.984, 111.429])
    _cell(out, String("h2o/q01_groupby_lowcard"), [11.394, 11.367, 11.367, 11.413, 11.369, 11.442, 11.384, 11.402, 11.469, 11.441])
    _cell(out, String("h2o/q02_groupby_2lowcard"), [27.642, 28.34, 28.71, 28.122, 28.639, 28.463, 28.044, 27.697, 28.09, 28.214])
    _cell(out, String("h2o/q03_groupby_highcard"), [133.048, 134.005, 135.208, 127.587, 133.815, 132.984, 135.454, 134.144, 135.268, 132.92])
    _cell(out, String("h2o/q04_groupby_intkey_multiagg"), [15.884, 15.648, 15.757, 16.311, 18.608, 15.909, 15.663, 15.602, 15.834, 15.772])
    _cell(out, String("h2o/q05_groupby_highcard_int"), [154.43, 151.42, 152.652, 150.562, 155.29, 151.84, 153.34, 153.326, 154.441, 152.726])
    _cell(out, String("h2o/q06_groupby_stats"), [142.194, 141.29, 142.025, 139.048, 143.128, 139.631, 142.171, 141.748, 140.929, 141.527])
    _cell(out, String("h2o/q07_groupby_range"), [143.875, 143.596, 142.889, 142.917, 143.827, 144.098, 142.506, 144.384, 144.698, 144.608])
    _cell(out, String("h2o/q08_groupby_topn"), [101.218, 102.004, 101.294, 100.741, 101.941, 101.106, 103.045, 102.496, 102.631, 101.285])
    _cell(out, String("h2o/q09_groupby_corr"), [49.879, 51.149, 50.316, 50.696, 50.744, 50.632, 51.085, 50.631, 50.531, 50.335])
    _cell(out, String("h2o/q10_groupby_6key"), [274.197, 272.199, 276.941, 273.216, 277.548, 274.02, 272.868, 276.558, 279.637, 276.613])
    _cell(out, String("hc/hc1_agg_25m_int"), [37.223, 35.839, 36.177, 38.581, 35.807, 37.925, 35.905, 35.316, 35.531, 35.613])
    _cell(out, String("hc/hc2_agg_100m_multi"), [51.868, 50.092, 54.66, 54.176, 51.804, 52.797, 53.906, 52.478, 50.413, 50.586])
    _cell(out, String("hc/hc3_agg_25m_float"), [29.286, 30.27, 34.942, 30.263, 30.87, 30.515, 31.448, 29.525, 30.705, 29.323])
    _cell(out, String("hc/hc4_join_high_card"), [17.789, 17.16, 17.49, 17.236, 17.347, 17.424, 14.783, 17.46, 17.378, 17.769])
    _cell(out, String("sdk/a1_passthrough"), [29.231, 29.474, 28.957, 31.213, 31.697, 29.288, 28.878, 28.982, 30.315, 29.2])
    _cell(out, String("sdk/a2_map"), [30.755, 32.286, 34.536, 31.382, 31.963, 30.959, 33.703, 31.522, 34.298, 31.521])
    _cell(out, String("sdk/b1_agg_lowcard"), [9.68, 9.805, 10.054, 9.775, 9.859, 9.801, 9.918, 9.688, 9.831, 9.842])
    _cell(out, String("sdk/b2_agg_highcard"), [109.814, 107.358, 103.13, 105.571, 106.432, 108.646, 106.649, 107.828, 105.506, 106.433])
    _cell(out, String("sdk/b5_tpch_q1"), [35.472, 34.85, 33.175, 34.294, 34.546, 34.587, 34.717, 34.837, 34.767, 34.416])
    _cell(out, String("sdk/c1_inner_join"), [23.155, 22.907, 22.955, 22.94, 23.16, 23.12, 23.341, 23.216, 23.041, 23.141])
    _cell(out, String("sdk/c2_left_join"), [26.749, 26.319, 26.586, 26.32, 26.376, 26.421, 26.606, 26.658, 26.182, 26.61])
    _cell(out, String("sdk/c3_semi_join"), [15.436, 15.185, 15.188, 15.027, 15.74, 15.4, 15.777, 15.365, 15.198, 15.582])
    _cell(out, String("sdk/c4_anti_join"), [13.649, 13.152, 13.192, 13.078, 13.74, 13.344, 13.645, 13.491, 13.29, 13.326])
    _cell(out, String("sdk/d1_agg_spill"), [25.291, 26.937, 25.6, 25.213, 25.268, 26.141, 27.14, 24.527, 24.577, 24.444])
    _cell(out, String("sdk/d2_join_spill"), [192.915, 191.315, 189.753, 190.894, 187.948, 188.583, 191.921, 192.523, 190.806, 188.463])
    _cell(out, String("sdk/e1_sort_merge_join"), [23.344, 23.146, 23.257, 23.045, 23.055, 23.017, 23.118, 23.411, 23.253, 23.083])
    _cell(out, String("sdk/e2_smj_vs_hj"), [23.508, 23.171, 23.232, 23.873, 22.712, 22.841, 22.973, 23.278, 23.043, 22.995])
    _cell(out, String("sdk/f1_filter_1pct"), [11.492, 11.431, 11.509, 11.59, 11.393, 11.505, 11.48, 11.562, 11.488, 11.437])
    _cell(out, String("sdk/f2_filter_8pct"), [12.749, 12.597, 13.227, 12.723, 12.57, 12.631, 12.626, 12.618, 12.579, 12.52])
    _cell(out, String("sdk/f3_compound_and"), [18.607, 18.544, 19.588, 18.97, 18.549, 18.577, 18.547, 18.587, 18.425, 18.658])
    _cell(out, String("sdk/f4_string_eq"), [17.669, 17.681, 18.046, 17.802, 17.685, 17.659, 17.701, 17.72, 17.784, 17.755])
    _cell(out, String("sdk/g1_parquet_write"), [12.357, 12.25, 12.162, 12.347, 12.914, 11.692, 12.444, 13.546, 11.679, 12.36])
    _cell(out, String("sdk/sdk_cse_demo"), [41.421, 41.032, 41.793, 41.178, 41.34, 41.042, 41.713, 41.441, 41.312, 41.127])
    _cell(out, String("tpch/q10_returned_item"), [46.224, 46.47, 45.37, 45.734, 45.379, 46.375, 46.079, 46.138, 46.446, 46.148])
    _cell(out, String("tpch/q11_important_stock"), [15.582, 15.91, 15.239, 15.133, 15.455, 15.61, 15.819, 15.805, 15.496, 15.369])
    _cell(out, String("tpch/q12_shipping_modes"), [4.123, 4.074, 3.652, 3.414, 3.724, 4.17, 4.012, 3.794, 4.015, 4.171])
    _cell(out, String("tpch/q13_customer_distribution"), [98.346, 94.161, 91.678, 90.432, 92.706, 97.561, 96.16, 93.412, 92.667, 92.129])
    _cell(out, String("tpch/q14_promotion_effect"), [6.18, 6.346, 6.089, 6.134, 6.287, 6.316, 6.098, 6.161, 6.299, 6.145])
    _cell(out, String("tpch/q15_top_supplier"), [7.719, 7.478, 7.555, 7.454, 7.595, 7.585, 7.528, 7.428, 7.593, 7.492])
    _cell(out, String("tpch/q16_parts_supplier"), [39.864, 39.326, 39.748, 39.115, 39.848, 39.532, 39.762, 39.522, 39.53, 39.596])
    _cell(out, String("tpch/q17_small_quantity_order"), [4.634, 4.765, 4.612, 4.552, 4.693, 4.678, 4.516, 4.624, 4.61, 4.607])
    _cell(out, String("tpch/q18_large_volume_customer"), [68.315, 68.518, 68.802, 68.001, 69.951, 77.667, 68.523, 68.689, 68.47, 69.881])
    _cell(out, String("tpch/q19_discounted_revenue"), [41.465, 42.133, 40.536, 41.25, 45.302, 39.273, 38.617, 41.713, 39.235, 43.927])
    _cell(out, String("tpch/q20_potential_part_promotion"), [84.157, 84.307, 84.066, 83.158, 85.108, 85.946, 83.76, 84.596, 86.304, 87.231])
    _cell(out, String("tpch/q21_suppliers_kept_waiting"), [105.234, 115.238, 103.405, 114.389, 98.476, 99.688, 113.523, 97.403, 101.766, 99.773])
    _cell(out, String("tpch/q22_global_sales_opportunity"), [10.838, 10.973, 10.872, 10.742, 10.959, 11.683, 11.444, 10.686, 10.785, 11.678])
    _cell(out, String("tpch/q2_minimum_cost_supplier"), [44.577, 44.507, 43.704, 43.421, 45.392, 46.987, 45.177, 43.6, 43.442, 45.999])
    _cell(out, String("tpch/q3_shipping_priority"), [57.971, 58.127, 57.841, 57.465, 61.217, 58.249, 59.275, 57.408, 57.066, 58.057])
    _cell(out, String("tpch/q4_order_priority"), [29.49, 29.733, 29.65, 29.635, 30.272, 30.904, 30.808, 30.059, 29.902, 31.211])
    _cell(out, String("tpch/q5_local_supplier"), [60.789, 59.318, 59.443, 58.909, 59.333, 62.087, 60.322, 59.595, 60.399, 61.059])
    _cell(out, String("tpch/q6_forecasting_revenue"), [19.257, 19.173, 19.272, 19.438, 19.416, 19.756, 20.073, 18.947, 18.886, 19.236])
    _cell(out, String("tpch/q7_volume_shipping"), [53.549, 53.02, 54.058, 51.989, 52.085, 54.274, 54.944, 52.774, 53.277, 53.489])
    _cell(out, String("tpch/q8_national_market_share"), [13.627, 14.241, 13.718, 15.198, 13.4, 15.18, 14.838, 13.956, 13.555, 14.272])
    _cell(out, String("tpch/q9_product_type_profit"), [165.038, 165.449, 163.489, 164.308, 162.457, 166.048, 174.2, 164.043, 165.061, 164.483])
    _cell(out, String("win/win_rank"), [0.699, 0.708, 0.71, 0.645, 0.728, 0.741, 0.739, 0.704, 0.637, 0.612])
    _cell(out, String("win/win_rolling"), [1.048, 1.094, 1.05, 1.085, 1.086, 1.115, 1.032, 1.046, 1.055, 1.061])
    _cell(out, String("win/win_running"), [1.037, 1.01, 0.976, 1.04, 0.99, 1.01, 1.015, 1.007, 1.055, 0.985])
    return out^


def _contains(haystack: String, needle: String) -> Bool:
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0 or len(n) > len(h):
        return len(n) == 0
    for i in range(len(h) - len(n) + 1):
        var hit = True
        for j in range(len(n)):
            if h[i + j] != n[j]:
                hit = False
                break
        if hit:
            return True
    return False


def _series_from(
    key: String, v: List[Float64], shift: Float64, extra: Int
) -> Series:
    """The 10 recorded points, optionally followed by `extra` more shifted by
    `shift`.

    ⚠ THE POST-CHANGE POINTS REUSE THE CELL'S OWN RECORDED VALUES, SCALED. A
    synthetic tail drawn from a clean distribution would make the detector look
    better than it is, because the post-change segment would be quieter than
    anything the machine produces. Reusing the observed values keeps the
    post-change noise exactly as bad as the pre-change noise.
    """
    var s = Series(key)
    for i in range(len(v)):
        s.append(Int64(i), v[i])
    for j in range(extra):
        s.append(Int64(len(v) + j), v[j] * (1.0 + shift))
    return s^


def _fires(
    cell: Cell, config: DetectorConfig, shift: Float64, extra: Int
) raises -> Bool:
    var s = _series_from(cell.key, cell.values, shift, extra)
    var det = SeriesDetector(cell.key, config)
    return det.evaluate(s).state == STATE_ANOMALY


def test_corpus_matches_the_documented_noise_floor() raises:
    """PROVENANCE. The fixture reproduces the recorded summary statistics.

    If someone edits these numbers, this goes red before any verdict about the
    detector is drawn from them — the calibration constant cannot drift
    silently away from the sweeps it was extracted from.
    """
    var corpus = known_zero_corpus()
    assert_equal(len(corpus), 82, "the sweeps scored 82 cells in all ten")

    var spreads = List[Float64]()
    var over_ten = 0
    var worst = Float64(0.0)
    for i in range(len(corpus)):
        var v = corpus[i].values.copy()
        var lo = v[0]
        var hi = v[0]
        for j in range(len(v)):
            assert_equal(len(v), 10, "every cell carries exactly ten sweeps")
            if v[j] < lo:
                lo = v[j]
            if v[j] > hi:
                hi = v[j]
        var spread = (hi - lo) / lo
        spreads.append(spread)
        if spread > 0.10:
            over_ten += 1
        if spread > worst:
            worst = spread

    var med = median_of(spreads)
    assert_true(
        med > 0.0495 and med < 0.0510,
        String("median per-cell spread must be the documented 5.03%; got ")
        + String(med),
    )
    assert_equal(
        over_ten, 14, "14 of 82 cells spread more than 10% at zero code change"
    )
    assert_true(
        worst > 0.2210 and worst < 0.2225,
        String("worst cell must be the documented 22.17%; got ") + String(worst),
    )


def test_known_zero_is_within_the_false_positive_budget() raises:
    """(1) THE CENTRAL CLAIM. Ten sweeps, one binary, no code change.

    The budget is AT MOST ONE firing across the corpus, which is what the
    per-cell significance 1/82 = 0.0122 buys. The measured value is ZERO.
    """
    var corpus = known_zero_corpus()
    var config = DetectorConfig()
    var fired = 0
    var names = String("")
    for i in range(len(corpus)):
        if _fires(corpus[i], config, Float64(0.0), 0):
            fired += 1
            names = names + String(" ") + corpus[i].key
    assert_true(
        fired <= 1,
        String("FALSE POSITIVES over budget: ")
        + String(fired)
        + String(" of 82 cells fired on data with no code change in it —")
        + String(" budget is <=1 per corpus run. Cells:")
        + names,
    )
    # ⭐ THE BUDGET IS THE CONTRACT; THE EXACT COUNT IS THE REGRESSION GUARD,
    # AND WITHOUT IT THE CONTRACT IS SLACK. The measured value is ZERO and the
    # budget is one, so a change that doubled the false-alarm rate from nothing
    # to one firing would leave the assertion above green. The detector is
    # deterministic — seeded permutations, a fixed fixture — so there is no
    # reason to accept a range here, and every reason not to: this exact number
    # is what `__init__.mojo` publishes as the case for the whole package.
    assert_equal(
        fired,
        0,
        String("the published figure is ZERO false positives at alpha=0.0122")
        + String(" on the 82 known-zero cells. Got ")
        + String(fired)
        + String(". Cells:")
        + names,
    )
    print(
        String("known-zero false positives at alpha=")
        + String(DEFAULT_SIGNIFICANCE)
        + String(", n=10 (change-point arm only): ")
        + String(fired)
        + String(" of 82 (budget <=1)")
    )

    # ⭐ THE SECOND ARM, AND IT IS NOT OPTIONAL. At n=10 the CUSUM chart does
    # not run at all, so a false-positive rate measured only there would be a
    # rate for the CHANGE-POINT arm alone and would say nothing about the other
    # one. Extending each series with five more recorded values from the SAME
    # binary keeps the data a known zero while putting the detector on the code
    # path where both arms are consulted.
    #
    # ⚠ WHAT THIS ARM ESTABLISHES, EXACTLY. At n=15 the chart DECLINES — its
    # reference must be at least `CUSUM_MIN_REFERENCE` = 20 — so what is proved
    # here is that a series long enough to reach the chart still comes in under
    # budget, WITH the decline recorded in the verdict rather than passed over
    # in silence. It is NOT a measurement of the chart's own false-alarm rate;
    # that stays unmeasured on real data until series reach ~25 points, and
    # `cusum.mojo`'s header says so.
    var both = 0
    var both_names = String("")
    var declines = 0
    var config15 = DetectorConfig()
    for i in range(len(corpus)):
        var s15 = _series_from(
            corpus[i].key, corpus[i].values, Float64(0.0), 5
        )
        var det15 = SeriesDetector(corpus[i].key, config15)
        var v15 = det15.evaluate(s15)
        if v15.state == STATE_ANOMALY:
            both += 1
            both_names = both_names + String(" ") + corpus[i].key
        if _contains(v15.detail, String("cusum_declined=")):
            declines += 1
    assert_true(
        both <= 1,
        String("FALSE POSITIVES over budget at n=15: ")
        + String(both)
        + String(" of 82. Cells:")
        + both_names,
    )
    assert_equal(
        both,
        0,
        String("and the measured value at n=15 is ZERO, not merely within")
        + String(" budget. Got ")
        + String(both)
        + String(". Cells:")
        + both_names,
    )
    assert_equal(
        declines,
        82,
        "at n=15 every cell's chart must DECLINE (reference < 20) and must SAY"
        " SO in the verdict — a silent decline is indistinguishable from a"
        " chart that ran and found nothing",
    )
    print(
        String("known-zero false positives at alpha=")
        + String(DEFAULT_SIGNIFICANCE)
        + String(", n=15: ")
        + String(both)
        + String(" of 82 (budget <=1; the CUSUM arm declined on all 82,")
        + String(" reference<20, and every verdict records that)")
    )


def test_the_budget_is_what_buys_the_zero_not_the_method() raises:
    """(2) THE ANTI-VACUOUS ARM.

    Run the SAME detector on the SAME data at the naive alpha = 0.05 and it
    goes over budget. Without this, a detector that never fires at all would
    pass the test above, and the zero would be evidence of deafness rather
    than of calibration.
    """
    var corpus = known_zero_corpus()
    var loose = DetectorConfig(significance=Float64(0.05))
    var fired = 0
    for i in range(len(corpus)):
        if _fires(corpus[i], loose, Float64(0.0), 0):
            fired += 1
    assert_true(
        fired > 1,
        String("at alpha=0.05 the detector should exceed the <=1 budget on")
        + String(" this data — if it does not, the corpus-wide correction is")
        + String(" not what is producing the zero. Got ")
        + String(fired),
    )
    # ⚠ AND THE EXACT NUMBER, WHICH IS **2**. This assertion is where the
    # figure lives, because it is the only place that recomputes it.
    assert_equal(
        fired,
        2,
        String("at alpha=0.05 exactly 2 of the 82 known-zero cells fire")
        + String(" (sdk/d1_agg_spill and tpch/q4_order_priority). Got ")
        + String(fired),
    )
    print(
        String("known-zero false positives at alpha=0.05: ")
        + String(fired)
        + String(" of 82 (over the <=1 budget — this is why 0.0122)")
    )


def test_detector_has_power_against_a_real_shift() raises:
    """(3) IT IS NOT DEAF. Five post-change points, on the same noisy cells.

    ── ⛔ THE BUDGETS THIS TEST USED TO CARRY DID NOT GUARD ANYTHING.

    It asserted `hit10 >= 65` and `hit30 >= 78` while the measured values were
    74 and 82. A change that lost NINE cells of power at +10% — an eighth of
    the detector's whole sensitivity — would have left it green, and the number
    `__init__.mojo` publishes (90.2%, i.e. 74 of 82) was printed and never
    checked. The detector is deterministic, so the counts are exact and are
    asserted as exact.

    ⚠ AND THE +20% ROW IS HERE BECAUSE THE PUBLISHED CLAIM IS ABOUT +20%.
    `__init__.mojo` quoted "a 20% shift 98.8%" while this file measured +30%
    and never +20% at all — a number nothing in the tree re-derived. Measured:
    +20% is caught on 82 of 82, i.e. 100%, so 98.8% was wrong as well as
    unchecked. This assertion is now where that figure lives.
    """
    var corpus = known_zero_corpus()
    var config = DetectorConfig()

    var hit10 = 0
    var hit20 = 0
    var hit30 = 0
    for i in range(len(corpus)):
        if _fires(corpus[i], config, Float64(0.10), 5):
            hit10 += 1
        if _fires(corpus[i], config, Float64(0.20), 5):
            hit20 += 1
        if _fires(corpus[i], config, Float64(0.30), 5):
            hit30 += 1

    print(
        String("power with 5 post-change points: +10% -> ")
        + String(hit10)
        + String("/82, +20% -> ")
        + String(hit20)
        + String("/82, +30% -> ")
        + String(hit30)
        + String("/82")
    )
    assert_equal(
        hit10,
        74,
        String("a 10% regression is caught on exactly 74 of 82 cells — the")
        + String(" 90.2% `__init__.mojo` publishes. Got ")
        + String(hit10),
    )
    assert_equal(
        hit20,
        82,
        String("a 20% regression is caught on every one of the 82 cells. Got ")
        + String(hit20),
    )
    assert_equal(
        hit30,
        82,
        String("a 30% regression is caught on every one of the 82 cells. Got ")
        + String(hit30),
    )


def test_a_fixed_threshold_fails_this_same_known_zero() raises:
    """(4) THE FIXED THRESHOLD, MEASURED RATHER THAN ASSERTED.

    A fixed-threshold check fails when a median wall time exceeds
    1.10x its baseline. Run that rule over ten sweeps of ONE binary and it
    fires repeatedly — every one of those firings is false, because nothing
    changed. This is the argument for replacing it, expressed as a
    measurement.
    """
    var corpus = known_zero_corpus()
    var firings = 0
    var cells = 0
    var prev_firings = 0
    var prev_cells = 0
    for i in range(len(corpus)):
        var v = corpus[i].values.copy()
        var base = v[0]
        var this_cell = 0
        var this_prev = 0
        for j in range(1, len(v)):
            if v[j] > 1.10 * base:
                this_cell += 1
            # ⭐ THE SECOND SPELLING. `__init__.mojo` quotes both '1.10x vs a
            # fixed baseline' and '1.10x vs the previous sweep', so both are
            # computed here. A published comparison nothing re-derives is a
            # sentence, not a measurement.
            if v[j] > 1.10 * v[j - 1]:
                this_prev += 1
        firings += this_cell
        if this_cell > 0:
            cells += 1
        prev_firings += this_prev
        if this_prev > 0:
            prev_cells += 1
    print(
        String("incumbent 1.10x-vs-baseline on the SAME known zero: ")
        + String(firings)
        + String(" firings across ")
        + String(cells)
        + String(" distinct cells (all false); 1.10x-vs-previous-sweep: ")
        + String(prev_firings)
        + String(" firings across ")
        + String(prev_cells)
        + String(" distinct cells")
    )
    assert_true(
        firings > 1,
        String("the 1.10x rule is expected to exceed the <=1 budget on")
        + String(" zero-change data; got ")
        + String(firings),
    )
    # The exact pair `__init__.mojo` publishes. Both halves, both spellings.
    assert_equal(
        firings,
        10,
        String("1.10x vs a FIXED BASELINE fires exactly 10 times on this")
        + String(" known zero. Got ")
        + String(firings),
    )
    assert_equal(
        cells,
        7,
        String("...across exactly 7 distinct cells. Got ") + String(cells),
    )
    assert_equal(
        prev_firings,
        12,
        String("1.10x vs the PREVIOUS SWEEP fires exactly 12 times. Got ")
        + String(prev_firings),
    )
    assert_equal(
        prev_cells,
        10,
        String("...across exactly 10 distinct cells. Got ")
        + String(prev_cells),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
