# =============================================================================
# ConcatOptions -- the concat's route switches and diagnostics, as a VALUE
# =============================================================================
#
# Every field is a switch that was once read from the process environment, once
# per concat CALL. They are arguments now: the caller decides, and nothing in
# this package reads the environment. The defaults are the shipped behaviour, so
# a caller that passes nothing gets the shipped route.
#
# The first four are KILL SWITCHES and A/B arms, not feature flags: turning one
# off restores the incumbent route byte for byte, which is what a byte-
# equivalence oracle compares against. `tiling` is the OUTER switch; the
# `string_tiling` and `string_bytebal` switches are read only after it has
# admitted the tiled route, so the outer OFF arm cannot be reached by clearing
# only one of the three.


struct ConcatOptions(Copyable, ImplicitlyCopyable, Movable):
    """Route switches and diagnostics for `concat_record_batches_column_parallel`.

    Fields:
      * `tiling` -- the row-range TILED route. ON (default) lets the tiling rule
        cut columns across the pool; OFF restores the `num_cols` fan (one task
        per column), and with it the serial route for a one-column input.
      * `string_tiling` -- STRING / BINARY columns take the tiled route. OFF
        puts them back on the whole-column route and leaves fixed-width tiling
        exactly as it is. Read only when `tiling` is ON.
      * `string_bytebal` -- STRING / BINARY tiles are cut at equal PAYLOAD BYTES
        rather than equal ROW ranges. Read only on the string-tiled route.
      * `force_tiles` -- pin 3 tiles per splittable column, bypassing the row
        and byte gates (not `tiling`). A byte-equivalence fixture, so that
        cross-tile disjoint writes and an uneven remainder are exercised on an
        input the rule would correctly decline.
      * `dict_unify` -- unify STRING-dictionary columns across batches before
        the concat. OFF restores the pair-wise fold.
      * `trace` -- print one line per concat call: the shape, the bytes, and the
        fan that shape produced.
      * `trace_dict_unify` -- print the unify phase timings.
      * `trace_geometry` -- print the realised grain geometry of each fan.
    """

    var tiling: Bool
    var string_tiling: Bool
    var string_bytebal: Bool
    var force_tiles: Bool
    var dict_unify: Bool
    var trace: Bool
    var trace_dict_unify: Bool
    var trace_geometry: Bool

    def __init__(
        out self,
        tiling: Bool = True,
        string_tiling: Bool = True,
        string_bytebal: Bool = True,
        force_tiles: Bool = False,
        dict_unify: Bool = True,
        trace: Bool = False,
        trace_dict_unify: Bool = False,
        trace_geometry: Bool = False,
    ):
        self.tiling = tiling
        self.string_tiling = string_tiling
        self.string_bytebal = string_bytebal
        self.force_tiles = force_tiles
        self.dict_unify = dict_unify
        self.trace = trace
        self.trace_dict_unify = trace_dict_unify
        self.trace_geometry = trace_geometry
