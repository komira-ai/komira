# =============================================================================
# komira_git/sha1dc_ubc.mojo -- the disturbance vectors of sha1dc and their
# unavoidable bit conditions.
# =============================================================================
#
# Data and one function of sha1collisiondetection (MIT License, notice at
# the end of this header), lib/ubc_check.c of release stable-v1.0.3, carried
# into Mojo:
#
#   * the 32 disturbance vectors (DVs) sha1dc checks, in upstream's
#     `sha1_dvs` order: type (1 for I, 2 for II), K, b, and the step whose
#     state the check recompresses from (58 or 65). Upstream's `maskb` of DV
#     i is i, and its `maski` is 0 for every DV.
#   * each DV's message difference `dm`, its first 16 words only: upstream
#     stores all 80, and every one of its 80-word rows is the SHA-1 message
#     expansion of its first 16 words, so `sha1dc.mojo` expands them as it
#     expands a message block.
#   * `_ubc_check`, upstream's `ubc_check` statement for statement: from an
#     expanded message block it computes the mask of the DVs whose
#     unavoidable bit conditions the block meets (bit i is DV i). A DV whose
#     bit is clear cannot be the difference of a collision block, so sha1dc
#     skips its recompression.
#
# komira_git_conformance checks all three against the C library: the DV
# fields and all 80 `dm` words of every DV, and the mask of random blocks.
#
# -----------------------------------------------------------------------------
# Upstream attribution (sha1collisiondetection, LICENSE.txt):
#
#   MIT License
#
#   Copyright (c) 2017:
#       Marc Stevens
#       Cryptology Group
#       Centrum Wiskunde & Informatica
#       P.O. Box 94079, 1090 GB Amsterdam, Netherlands
#       marc@marc-stevens.nl
#
#       Dan Shumow
#       Microsoft Research
#       danshu@microsoft.com
#
#   Permission is hereby granted, free of charge, to any person obtaining a
#   copy of this software and associated documentation files (the
#   "Software"), to deal in the Software without restriction, including
#   without limitation the rights to use, copy, modify, merge, publish,
#   distribute, sublicense, and/or sell copies of the Software, and to permit
#   persons to whom the Software is furnished to do so, subject to the
#   following conditions:
#
#   The above copyright notice and this permission notice shall be included
#   in all copies or substantial portions of the Software.
#
#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
#   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
#   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
#   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
#   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
#   USE OR OTHER DEALINGS IN THE SOFTWARE.
# =============================================================================

from std.builtin.globals import global_constant

comptime _DV_COUNT: Int = 32
"""The number of disturbance vectors sha1dc checks."""

comptime _ALL_DVS: UInt32 = UInt32((1 << _DV_COUNT) - 1)
"""The ubc mask with every DV's bit set: the mask checked when the filter is
off."""

# Bit i of a ubc mask is DV i (upstream's DV_<type>_<K>_<b>_bit).
comptime _DV_I_43_0: UInt32 = 1 << 0
comptime _DV_I_44_0: UInt32 = 1 << 1
comptime _DV_I_45_0: UInt32 = 1 << 2
comptime _DV_I_46_0: UInt32 = 1 << 3
comptime _DV_I_46_2: UInt32 = 1 << 4
comptime _DV_I_47_0: UInt32 = 1 << 5
comptime _DV_I_47_2: UInt32 = 1 << 6
comptime _DV_I_48_0: UInt32 = 1 << 7
comptime _DV_I_48_2: UInt32 = 1 << 8
comptime _DV_I_49_0: UInt32 = 1 << 9
comptime _DV_I_49_2: UInt32 = 1 << 10
comptime _DV_I_50_0: UInt32 = 1 << 11
comptime _DV_I_50_2: UInt32 = 1 << 12
comptime _DV_I_51_0: UInt32 = 1 << 13
comptime _DV_I_51_2: UInt32 = 1 << 14
comptime _DV_I_52_0: UInt32 = 1 << 15
comptime _DV_II_45_0: UInt32 = 1 << 16
comptime _DV_II_46_0: UInt32 = 1 << 17
comptime _DV_II_46_2: UInt32 = 1 << 18
comptime _DV_II_47_0: UInt32 = 1 << 19
comptime _DV_II_48_0: UInt32 = 1 << 20
comptime _DV_II_49_0: UInt32 = 1 << 21
comptime _DV_II_49_2: UInt32 = 1 << 22
comptime _DV_II_50_0: UInt32 = 1 << 23
comptime _DV_II_50_2: UInt32 = 1 << 24
comptime _DV_II_51_0: UInt32 = 1 << 25
comptime _DV_II_51_2: UInt32 = 1 << 26
comptime _DV_II_52_0: UInt32 = 1 << 27
comptime _DV_II_53_0: UInt32 = 1 << 28
comptime _DV_II_54_0: UInt32 = 1 << 29
comptime _DV_II_55_0: UInt32 = 1 << 30
comptime _DV_II_56_0: UInt32 = 1 << 31

# fmt: off
# Per DV, in upstream's order: type (1 I, 2 II), K, b, recompression step.
comptime _DV_INFO: InlineArray[Int, 4 * _DV_COUNT] = [
    1, 43, 0, 58,  # 0
    1, 44, 0, 58,  # 1
    1, 45, 0, 58,  # 2
    1, 46, 0, 58,  # 3
    1, 46, 2, 58,  # 4
    1, 47, 0, 58,  # 5
    1, 47, 2, 58,  # 6
    1, 48, 0, 58,  # 7
    1, 48, 2, 58,  # 8
    1, 49, 0, 58,  # 9
    1, 49, 2, 58,  # 10
    1, 50, 0, 65,  # 11
    1, 50, 2, 65,  # 12
    1, 51, 0, 65,  # 13
    1, 51, 2, 65,  # 14
    1, 52, 0, 65,  # 15
    2, 45, 0, 58,  # 16
    2, 46, 0, 58,  # 17
    2, 46, 2, 58,  # 18
    2, 47, 0, 58,  # 19
    2, 48, 0, 58,  # 20
    2, 49, 0, 58,  # 21
    2, 49, 2, 58,  # 22
    2, 50, 0, 65,  # 23
    2, 50, 2, 65,  # 24
    2, 51, 0, 65,  # 25
    2, 51, 2, 65,  # 26
    2, 52, 0, 65,  # 27
    2, 53, 0, 65,  # 28
    2, 54, 0, 65,  # 29
    2, 55, 0, 65,  # 30
    2, 56, 0, 65,  # 31
]

# Per DV, the first 16 words of its message difference `dm`.
comptime _DV_DM16: InlineArray[UInt32, 16 * _DV_COUNT] = [
    # 0: DV I(43,0), tested at step 58
    0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008,
    0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000, 0x20000010, 0x48000000, 0x08000018,
    # 1: DV I(44,0), tested at step 58
    0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000,
    0x00000008, 0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000, 0x20000010, 0x48000000,
    # 2: DV I(45,0), tested at step 58
    0xf4000014, 0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000,
    0x60000000, 0x00000008, 0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000, 0x20000010,
    # 3: DV I(46,0), tested at step 58
    0x2c000010, 0xf4000014, 0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010,
    0x98000000, 0x60000000, 0x00000008, 0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000,
    # 4: DV I(46,2), tested at step 58
    0xb0000040, 0xd0000053, 0xd0000022, 0x20000000, 0x60000032, 0x60000043, 0x20000040, 0xe0000042,
    0x60000002, 0x80000001, 0x00000020, 0x00000003, 0x40000052, 0x40000040, 0xe0000052, 0xa0000000,
    # 5: DV I(47,0), tested at step 58
    0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010,
    0xb8000010, 0x98000000, 0x60000000, 0x00000008, 0xc0000000, 0x90000014, 0x10000010, 0xb8000014,
    # 6: DV I(47,2), tested at step 58
    0x20000043, 0xb0000040, 0xd0000053, 0xd0000022, 0x20000000, 0x60000032, 0x60000043, 0x20000040,
    0xe0000042, 0x60000002, 0x80000001, 0x00000020, 0x00000003, 0x40000052, 0x40000040, 0xe0000052,
    # 7: DV I(48,0), tested at step 58
    0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008, 0x08000000, 0x9800000c, 0xd8000010,
    0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008, 0xc0000000, 0x90000014, 0x10000010,
    # 8: DV I(48,2), tested at step 58
    0xe000002a, 0x20000043, 0xb0000040, 0xd0000053, 0xd0000022, 0x20000000, 0x60000032, 0x60000043,
    0x20000040, 0xe0000042, 0x60000002, 0x80000001, 0x00000020, 0x00000003, 0x40000052, 0x40000040,
    # 9: DV I(49,0), tested at step 58
    0x18000000, 0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008, 0x08000000, 0x9800000c,
    0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008, 0xc0000000, 0x90000014,
    # 10: DV I(49,2), tested at step 58
    0x60000000, 0xe000002a, 0x20000043, 0xb0000040, 0xd0000053, 0xd0000022, 0x20000000, 0x60000032,
    0x60000043, 0x20000040, 0xe0000042, 0x60000002, 0x80000001, 0x00000020, 0x00000003, 0x40000052,
    # 11: DV I(50,0), tested at step 65
    0x0800000c, 0x18000000, 0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008, 0x08000000,
    0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008, 0xc0000000,
    # 12: DV I(50,2), tested at step 65
    0x20000030, 0x60000000, 0xe000002a, 0x20000043, 0xb0000040, 0xd0000053, 0xd0000022, 0x20000000,
    0x60000032, 0x60000043, 0x20000040, 0xe0000042, 0x60000002, 0x80000001, 0x00000020, 0x00000003,
    # 13: DV I(51,0), tested at step 65
    0xe8000000, 0x0800000c, 0x18000000, 0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008,
    0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008,
    # 14: DV I(51,2), tested at step 65
    0xa0000003, 0x20000030, 0x60000000, 0xe000002a, 0x20000043, 0xb0000040, 0xd0000053, 0xd0000022,
    0x20000000, 0x60000032, 0x60000043, 0x20000040, 0xe0000042, 0x60000002, 0x80000001, 0x00000020,
    # 15: DV I(52,0), tested at step 65
    0x04000010, 0xe8000000, 0x0800000c, 0x18000000, 0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014,
    0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000,
    # 16: DV II(45,0), tested at step 58
    0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c,
    0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c, 0xe8000000, 0xb0000004,
    # 17: DV II(46,0), tested at step 58
    0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010,
    0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c, 0xe8000000,
    # 18: DV II(46,2), tested at step 58
    0x90000070, 0xb0000053, 0x30000008, 0x00000043, 0xd0000072, 0xb0000010, 0xf0000062, 0xc0000042,
    0x00000030, 0xe0000042, 0x20000060, 0xe0000041, 0x20000050, 0xc0000041, 0xe0000072, 0xa0000003,
    # 19: DV II(47,0), tested at step 58
    0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018,
    0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c,
    # 20: DV II(48,0), tested at step 58
    0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004,
    0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010,
    # 21: DV II(49,0), tested at step 58
    0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c,
    0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014,
    # 22: DV II(49,2), tested at step 58
    0xf0000010, 0xf000006a, 0x80000040, 0x90000070, 0xb0000053, 0x30000008, 0x00000043, 0xd0000072,
    0xb0000010, 0xf0000062, 0xc0000042, 0x00000030, 0xe0000042, 0x20000060, 0xe0000041, 0x20000050,
    # 23: DV II(50,0), tested at step 65
    0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010,
    0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010,
    # 24: DV II(50,2), tested at step 65
    0xd0000072, 0xf0000010, 0xf000006a, 0x80000040, 0x90000070, 0xb0000053, 0x30000008, 0x00000043,
    0xd0000072, 0xb0000010, 0xf0000062, 0xc0000042, 0x00000030, 0xe0000042, 0x20000060, 0xe0000041,
    # 25: DV II(51,0), tested at step 65
    0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002,
    0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010, 0x08000018,
    # 26: DV II(51,2), tested at step 65
    0x00000043, 0xd0000072, 0xf0000010, 0xf000006a, 0x80000040, 0x90000070, 0xb0000053, 0x30000008,
    0x00000043, 0xd0000072, 0xb0000010, 0xf0000062, 0xc0000042, 0x00000030, 0xe0000042, 0x20000060,
    # 27: DV II(52,0), tested at step 65
    0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c, 0xec000014,
    0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010,
    # 28: DV II(53,0), tested at step 65
    0xcc000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c,
    0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c,
    # 29: DV II(54,0), tested at step 65
    0x0400001c, 0xcc000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010,
    0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010,
    # 30: DV II(55,0), tested at step 65
    0x00000010, 0x0400001c, 0xcc000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a,
    0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018,
    # 31: DV II(56,0), tested at step 65
    0x2600001a, 0x00000010, 0x0400001c, 0xcc000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004,
    0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004,
]
# fmt: on


@always_inline
def _dv_field(dv: Int, field: Int) -> Int:
    """Field `field` of DV `dv`: 0 type, 1 K, 2 b, 3 recompression step."""
    return global_constant[_DV_INFO]()[4 * dv + field]


@always_inline
def _dv_word(dv: Int, t: Int) -> UInt32:
    """Word `t` (0 <= t < 16) of DV `dv`'s message difference."""
    return global_constant[_DV_DM16]()[16 * dv + t]


def _ubc_check(w: InlineArray[UInt32, 80]) -> UInt32:
    """The mask of the DVs whose unavoidable bit conditions the expanded
    message block `w` meets (upstream's `ubc_check`)."""
    var mask: UInt32 = 0xFFFFFFFF
    mask &= (((((w[44]^w[45])>>29)&1)-1) | ~(_DV_I_48_0|_DV_I_51_0|_DV_I_52_0|_DV_II_45_0|_DV_II_46_0|_DV_II_50_0|_DV_II_51_0))
    mask &= (((((w[49]^w[50])>>29)&1)-1) | ~(_DV_I_46_0|_DV_II_45_0|_DV_II_50_0|_DV_II_51_0|_DV_II_55_0|_DV_II_56_0))
    mask &= (((((w[48]^w[49])>>29)&1)-1) | ~(_DV_I_45_0|_DV_I_52_0|_DV_II_49_0|_DV_II_50_0|_DV_II_54_0|_DV_II_55_0))
    mask &= ((((w[47]^(w[50]>>25))&(1<<4))-(1<<4)) | ~(_DV_I_47_0|_DV_I_49_0|_DV_I_51_0|_DV_II_45_0|_DV_II_51_0|_DV_II_56_0))
    mask &= (((((w[47]^w[48])>>29)&1)-1) | ~(_DV_I_44_0|_DV_I_51_0|_DV_II_48_0|_DV_II_49_0|_DV_II_53_0|_DV_II_54_0))
    mask &= (((((w[46]>>4)^(w[49]>>29))&1)-1) | ~(_DV_I_46_0|_DV_I_48_0|_DV_I_50_0|_DV_I_52_0|_DV_II_50_0|_DV_II_55_0))
    mask &= (((((w[46]^w[47])>>29)&1)-1) | ~(_DV_I_43_0|_DV_I_50_0|_DV_II_47_0|_DV_II_48_0|_DV_II_52_0|_DV_II_53_0))
    mask &= (((((w[45]>>4)^(w[48]>>29))&1)-1) | ~(_DV_I_45_0|_DV_I_47_0|_DV_I_49_0|_DV_I_51_0|_DV_II_49_0|_DV_II_54_0))
    mask &= (((((w[45]^w[46])>>29)&1)-1) | ~(_DV_I_49_0|_DV_I_52_0|_DV_II_46_0|_DV_II_47_0|_DV_II_51_0|_DV_II_52_0))
    mask &= (((((w[44]>>4)^(w[47]>>29))&1)-1) | ~(_DV_I_44_0|_DV_I_46_0|_DV_I_48_0|_DV_I_50_0|_DV_II_48_0|_DV_II_53_0))
    mask &= (((((w[43]>>4)^(w[46]>>29))&1)-1) | ~(_DV_I_43_0|_DV_I_45_0|_DV_I_47_0|_DV_I_49_0|_DV_II_47_0|_DV_II_52_0))
    mask &= (((((w[43]^w[44])>>29)&1)-1) | ~(_DV_I_47_0|_DV_I_50_0|_DV_I_51_0|_DV_II_45_0|_DV_II_49_0|_DV_II_50_0))
    mask &= (((((w[42]>>4)^(w[45]>>29))&1)-1) | ~(_DV_I_44_0|_DV_I_46_0|_DV_I_48_0|_DV_I_52_0|_DV_II_46_0|_DV_II_51_0))
    mask &= (((((w[41]>>4)^(w[44]>>29))&1)-1) | ~(_DV_I_43_0|_DV_I_45_0|_DV_I_47_0|_DV_I_51_0|_DV_II_45_0|_DV_II_50_0))
    mask &= (((((w[40]^w[41])>>29)&1)-1) | ~(_DV_I_44_0|_DV_I_47_0|_DV_I_48_0|_DV_II_46_0|_DV_II_47_0|_DV_II_56_0))
    mask &= (((((w[54]^w[55])>>29)&1)-1) | ~(_DV_I_51_0|_DV_II_47_0|_DV_II_50_0|_DV_II_55_0|_DV_II_56_0))
    mask &= (((((w[53]^w[54])>>29)&1)-1) | ~(_DV_I_50_0|_DV_II_46_0|_DV_II_49_0|_DV_II_54_0|_DV_II_55_0))
    mask &= (((((w[52]^w[53])>>29)&1)-1) | ~(_DV_I_49_0|_DV_II_45_0|_DV_II_48_0|_DV_II_53_0|_DV_II_54_0))
    mask &= ((((w[50]^(w[53]>>25))&(1<<4))-(1<<4)) | ~(_DV_I_50_0|_DV_I_52_0|_DV_II_46_0|_DV_II_48_0|_DV_II_54_0))
    mask &= (((((w[50]^w[51])>>29)&1)-1) | ~(_DV_I_47_0|_DV_II_46_0|_DV_II_51_0|_DV_II_52_0|_DV_II_56_0))
    mask &= ((((w[49]^(w[52]>>25))&(1<<4))-(1<<4)) | ~(_DV_I_49_0|_DV_I_51_0|_DV_II_45_0|_DV_II_47_0|_DV_II_53_0))
    mask &= ((((w[48]^(w[51]>>25))&(1<<4))-(1<<4)) | ~(_DV_I_48_0|_DV_I_50_0|_DV_I_52_0|_DV_II_46_0|_DV_II_52_0))
    mask &= (((((w[42]^w[43])>>29)&1)-1) | ~(_DV_I_46_0|_DV_I_49_0|_DV_I_50_0|_DV_II_48_0|_DV_II_49_0))
    mask &= (((((w[41]^w[42])>>29)&1)-1) | ~(_DV_I_45_0|_DV_I_48_0|_DV_I_49_0|_DV_II_47_0|_DV_II_48_0))
    mask &= (((((w[40]>>4)^(w[43]>>29))&1)-1) | ~(_DV_I_44_0|_DV_I_46_0|_DV_I_50_0|_DV_II_49_0|_DV_II_56_0))
    mask &= (((((w[39]>>4)^(w[42]>>29))&1)-1) | ~(_DV_I_43_0|_DV_I_45_0|_DV_I_49_0|_DV_II_48_0|_DV_II_55_0))
    if (mask & (_DV_I_44_0|_DV_I_48_0|_DV_II_47_0|_DV_II_54_0|_DV_II_56_0)) != 0:
        mask &= (((((w[38]>>4)^(w[41]>>29))&1)-1) | ~(_DV_I_44_0|_DV_I_48_0|_DV_II_47_0|_DV_II_54_0|_DV_II_56_0))
    mask &= (((((w[37]>>4)^(w[40]>>29))&1)-1) | ~(_DV_I_43_0|_DV_I_47_0|_DV_II_46_0|_DV_II_53_0|_DV_II_55_0))
    if (mask & (_DV_I_52_0|_DV_II_48_0|_DV_II_51_0|_DV_II_56_0)) != 0:
        mask &= (((((w[55]^w[56])>>29)&1)-1) | ~(_DV_I_52_0|_DV_II_48_0|_DV_II_51_0|_DV_II_56_0))
    if (mask & (_DV_I_52_0|_DV_II_48_0|_DV_II_50_0|_DV_II_56_0)) != 0:
        mask &= ((((w[52]^(w[55]>>25))&(1<<4))-(1<<4)) | ~(_DV_I_52_0|_DV_II_48_0|_DV_II_50_0|_DV_II_56_0))
    if (mask & (_DV_I_51_0|_DV_II_47_0|_DV_II_49_0|_DV_II_55_0)) != 0:
        mask &= ((((w[51]^(w[54]>>25))&(1<<4))-(1<<4)) | ~(_DV_I_51_0|_DV_II_47_0|_DV_II_49_0|_DV_II_55_0))
    if (mask & (_DV_I_48_0|_DV_II_47_0|_DV_II_52_0|_DV_II_53_0)) != 0:
        mask &= (((((w[51]^w[52])>>29)&1)-1) | ~(_DV_I_48_0|_DV_II_47_0|_DV_II_52_0|_DV_II_53_0))
    if (mask & (_DV_I_46_0|_DV_I_49_0|_DV_II_45_0|_DV_II_48_0)) != 0:
        mask &= (((((w[36]>>4)^(w[40]>>29))&1)-1) | ~(_DV_I_46_0|_DV_I_49_0|_DV_II_45_0|_DV_II_48_0))
    if (mask & (_DV_I_52_0|_DV_II_48_0|_DV_II_49_0)) != 0:
        mask &= ((0-(((w[53]^w[56])>>29)&1)) | ~(_DV_I_52_0|_DV_II_48_0|_DV_II_49_0))
    if (mask & (_DV_I_50_0|_DV_II_46_0|_DV_II_47_0)) != 0:
        mask &= ((0-(((w[51]^w[54])>>29)&1)) | ~(_DV_I_50_0|_DV_II_46_0|_DV_II_47_0))
    if (mask & (_DV_I_49_0|_DV_I_51_0|_DV_II_45_0)) != 0:
        mask &= ((0-(((w[50]^w[52])>>29)&1)) | ~(_DV_I_49_0|_DV_I_51_0|_DV_II_45_0))
    if (mask & (_DV_I_48_0|_DV_I_50_0|_DV_I_52_0)) != 0:
        mask &= ((0-(((w[49]^w[51])>>29)&1)) | ~(_DV_I_48_0|_DV_I_50_0|_DV_I_52_0))
    if (mask & (_DV_I_47_0|_DV_I_49_0|_DV_I_51_0)) != 0:
        mask &= ((0-(((w[48]^w[50])>>29)&1)) | ~(_DV_I_47_0|_DV_I_49_0|_DV_I_51_0))
    if (mask & (_DV_I_46_0|_DV_I_48_0|_DV_I_50_0)) != 0:
        mask &= ((0-(((w[47]^w[49])>>29)&1)) | ~(_DV_I_46_0|_DV_I_48_0|_DV_I_50_0))
    if (mask & (_DV_I_45_0|_DV_I_47_0|_DV_I_49_0)) != 0:
        mask &= ((0-(((w[46]^w[48])>>29)&1)) | ~(_DV_I_45_0|_DV_I_47_0|_DV_I_49_0))
    mask &= ((((w[45]^w[47])&(1<<6))-(1<<6)) | ~(_DV_I_47_2|_DV_I_49_2|_DV_I_51_2))
    if (mask & (_DV_I_44_0|_DV_I_46_0|_DV_I_48_0)) != 0:
        mask &= ((0-(((w[45]^w[47])>>29)&1)) | ~(_DV_I_44_0|_DV_I_46_0|_DV_I_48_0))
    mask &= (((((w[44]^w[46])>>6)&1)-1) | ~(_DV_I_46_2|_DV_I_48_2|_DV_I_50_2))
    if (mask & (_DV_I_43_0|_DV_I_45_0|_DV_I_47_0)) != 0:
        mask &= ((0-(((w[44]^w[46])>>29)&1)) | ~(_DV_I_43_0|_DV_I_45_0|_DV_I_47_0))
    mask &= ((0-((w[41]^(w[42]>>5))&(1<<1))) | ~(_DV_I_48_2|_DV_II_46_2|_DV_II_51_2))
    mask &= ((0-((w[40]^(w[41]>>5))&(1<<1))) | ~(_DV_I_47_2|_DV_I_51_2|_DV_II_50_2))
    if (mask & (_DV_I_44_0|_DV_I_46_0|_DV_II_56_0)) != 0:
        mask &= ((0-(((w[40]^w[42])>>4)&1)) | ~(_DV_I_44_0|_DV_I_46_0|_DV_II_56_0))
    mask &= ((0-((w[39]^(w[40]>>5))&(1<<1))) | ~(_DV_I_46_2|_DV_I_50_2|_DV_II_49_2))
    if (mask & (_DV_I_43_0|_DV_I_45_0|_DV_II_55_0)) != 0:
        mask &= ((0-(((w[39]^w[41])>>4)&1)) | ~(_DV_I_43_0|_DV_I_45_0|_DV_II_55_0))
    if (mask & (_DV_I_44_0|_DV_II_54_0|_DV_II_56_0)) != 0:
        mask &= ((0-(((w[38]^w[40])>>4)&1)) | ~(_DV_I_44_0|_DV_II_54_0|_DV_II_56_0))
    if (mask & (_DV_I_43_0|_DV_II_53_0|_DV_II_55_0)) != 0:
        mask &= ((0-(((w[37]^w[39])>>4)&1)) | ~(_DV_I_43_0|_DV_II_53_0|_DV_II_55_0))
    mask &= ((0-((w[36]^(w[37]>>5))&(1<<1))) | ~(_DV_I_47_2|_DV_I_50_2|_DV_II_46_2))
    if (mask & (_DV_I_45_0|_DV_I_48_0|_DV_II_47_0)) != 0:
        mask &= (((((w[35]>>4)^(w[39]>>29))&1)-1) | ~(_DV_I_45_0|_DV_I_48_0|_DV_II_47_0))
    if (mask & (_DV_I_48_0|_DV_II_48_0)) != 0:
        mask &= ((0-((w[63]^(w[64]>>5))&(1<<0))) | ~(_DV_I_48_0|_DV_II_48_0))
    if (mask & (_DV_I_45_0|_DV_II_45_0)) != 0:
        mask &= ((0-((w[63]^(w[64]>>5))&(1<<1))) | ~(_DV_I_45_0|_DV_II_45_0))
    if (mask & (_DV_I_47_0|_DV_II_47_0)) != 0:
        mask &= ((0-((w[62]^(w[63]>>5))&(1<<0))) | ~(_DV_I_47_0|_DV_II_47_0))
    if (mask & (_DV_I_46_0|_DV_II_46_0)) != 0:
        mask &= ((0-((w[61]^(w[62]>>5))&(1<<0))) | ~(_DV_I_46_0|_DV_II_46_0))
    mask &= ((0-((w[61]^(w[62]>>5))&(1<<2))) | ~(_DV_I_46_2|_DV_II_46_2))
    if (mask & (_DV_I_45_0|_DV_II_45_0)) != 0:
        mask &= ((0-((w[60]^(w[61]>>5))&(1<<0))) | ~(_DV_I_45_0|_DV_II_45_0))
    if (mask & (_DV_II_51_0|_DV_II_54_0)) != 0:
        mask &= (((((w[58]^w[59])>>29)&1)-1) | ~(_DV_II_51_0|_DV_II_54_0))
    if (mask & (_DV_II_50_0|_DV_II_53_0)) != 0:
        mask &= (((((w[57]^w[58])>>29)&1)-1) | ~(_DV_II_50_0|_DV_II_53_0))
    if (mask & (_DV_II_52_0|_DV_II_54_0)) != 0:
        mask &= ((((w[56]^(w[59]>>25))&(1<<4))-(1<<4)) | ~(_DV_II_52_0|_DV_II_54_0))
    if (mask & (_DV_II_51_0|_DV_II_52_0)) != 0:
        mask &= ((0-(((w[56]^w[59])>>29)&1)) | ~(_DV_II_51_0|_DV_II_52_0))
    if (mask & (_DV_II_49_0|_DV_II_52_0)) != 0:
        mask &= (((((w[56]^w[57])>>29)&1)-1) | ~(_DV_II_49_0|_DV_II_52_0))
    if (mask & (_DV_II_51_0|_DV_II_53_0)) != 0:
        mask &= ((((w[55]^(w[58]>>25))&(1<<4))-(1<<4)) | ~(_DV_II_51_0|_DV_II_53_0))
    if (mask & (_DV_II_50_0|_DV_II_52_0)) != 0:
        mask &= ((((w[54]^(w[57]>>25))&(1<<4))-(1<<4)) | ~(_DV_II_50_0|_DV_II_52_0))
    if (mask & (_DV_II_49_0|_DV_II_51_0)) != 0:
        mask &= ((((w[53]^(w[56]>>25))&(1<<4))-(1<<4)) | ~(_DV_II_49_0|_DV_II_51_0))
    mask &= ((((w[51]^(w[50]>>5))&(1<<1))-(1<<1)) | ~(_DV_I_50_2|_DV_II_46_2))
    mask &= ((((w[48]^w[50])&(1<<6))-(1<<6)) | ~(_DV_I_50_2|_DV_II_46_2))
    if (mask & (_DV_I_51_0|_DV_I_52_0)) != 0:
        mask &= ((0-(((w[48]^w[55])>>29)&1)) | ~(_DV_I_51_0|_DV_I_52_0))
    mask &= ((((w[47]^w[49])&(1<<6))-(1<<6)) | ~(_DV_I_49_2|_DV_I_51_2))
    mask &= ((((w[48]^(w[47]>>5))&(1<<1))-(1<<1)) | ~(_DV_I_47_2|_DV_II_51_2))
    mask &= ((((w[46]^w[48])&(1<<6))-(1<<6)) | ~(_DV_I_48_2|_DV_I_50_2))
    mask &= ((((w[47]^(w[46]>>5))&(1<<1))-(1<<1)) | ~(_DV_I_46_2|_DV_II_50_2))
    mask &= ((0-((w[44]^(w[45]>>5))&(1<<1))) | ~(_DV_I_51_2|_DV_II_49_2))
    mask &= ((((w[43]^w[45])&(1<<6))-(1<<6)) | ~(_DV_I_47_2|_DV_I_49_2))
    mask &= (((((w[42]^w[44])>>6)&1)-1) | ~(_DV_I_46_2|_DV_I_48_2))
    mask &= ((((w[43]^(w[42]>>5))&(1<<1))-(1<<1)) | ~(_DV_II_46_2|_DV_II_51_2))
    mask &= ((((w[42]^(w[41]>>5))&(1<<1))-(1<<1)) | ~(_DV_I_51_2|_DV_II_50_2))
    mask &= ((((w[41]^(w[40]>>5))&(1<<1))-(1<<1)) | ~(_DV_I_50_2|_DV_II_49_2))
    if (mask & (_DV_I_52_0|_DV_II_51_0)) != 0:
        mask &= ((((w[39]^(w[43]>>25))&(1<<4))-(1<<4)) | ~(_DV_I_52_0|_DV_II_51_0))
    if (mask & (_DV_I_51_0|_DV_II_50_0)) != 0:
        mask &= ((((w[38]^(w[42]>>25))&(1<<4))-(1<<4)) | ~(_DV_I_51_0|_DV_II_50_0))
    if (mask & (_DV_I_48_2|_DV_I_51_2)) != 0:
        mask &= ((0-((w[37]^(w[38]>>5))&(1<<1))) | ~(_DV_I_48_2|_DV_I_51_2))
    if (mask & (_DV_I_50_0|_DV_II_49_0)) != 0:
        mask &= ((((w[37]^(w[41]>>25))&(1<<4))-(1<<4)) | ~(_DV_I_50_0|_DV_II_49_0))
    if (mask & (_DV_II_52_0|_DV_II_54_0)) != 0:
        mask &= ((0-((w[36]^w[38])&(1<<4))) | ~(_DV_II_52_0|_DV_II_54_0))
    mask &= ((0-((w[35]^(w[36]>>5))&(1<<1))) | ~(_DV_I_46_2|_DV_I_49_2))
    if (mask & (_DV_I_51_0|_DV_II_47_0)) != 0:
        mask &= ((((w[35]^(w[39]>>25))&(1<<3))-(1<<3)) | ~(_DV_I_51_0|_DV_II_47_0))
    if mask != 0:
        if (mask & _DV_I_43_0) != 0:
            if (
                ((w[61]^(w[62]>>5)) & (1<<1)) == 0
                or ((w[59]^(w[63]>>25)) & (1<<5)) != 0
                or ((w[58]^(w[63]>>30)) & (1<<0)) == 0
            ):
                mask &= ~_DV_I_43_0
        if (mask & _DV_I_44_0) != 0:
            if (
                ((w[62]^(w[63]>>5)) & (1<<1)) == 0
                or ((w[60]^(w[64]>>25)) & (1<<5)) != 0
                or ((w[59]^(w[64]>>30)) & (1<<0)) == 0
            ):
                mask &= ~_DV_I_44_0
        if (mask & _DV_I_46_2) != 0:
            mask &= ((~((w[40]^w[42])>>2)) | ~_DV_I_46_2)
        if (mask & _DV_I_47_2) != 0:
            if (
                ((w[62]^(w[63]>>5)) & (1<<2)) == 0
                or ((w[41]^w[43]) & (1<<6)) != 0
            ):
                mask &= ~_DV_I_47_2
        if (mask & _DV_I_48_2) != 0:
            if (
                ((w[63]^(w[64]>>5)) & (1<<2)) == 0
                or ((w[48]^(w[49]<<5)) & (1<<6)) != 0
            ):
                mask &= ~_DV_I_48_2
        if (mask & _DV_I_49_2) != 0:
            if (
                ((w[49]^(w[50]<<5)) & (1<<6)) != 0
                or ((w[42]^w[50]) & (1<<1)) == 0
                or ((w[39]^(w[40]<<5)) & (1<<6)) != 0
                or ((w[38]^w[40]) & (1<<1)) == 0
            ):
                mask &= ~_DV_I_49_2
        if (mask & _DV_I_50_0) != 0:
            mask &= ((((w[36]^w[37])<<7)) | ~_DV_I_50_0)
        if (mask & _DV_I_50_2) != 0:
            mask &= ((((w[43]^w[51])<<11)) | ~_DV_I_50_2)
        if (mask & _DV_I_51_0) != 0:
            mask &= ((((w[37]^w[38])<<9)) | ~_DV_I_51_0)
        if (mask & _DV_I_51_2) != 0:
            if (
                ((w[51]^(w[52]<<5)) & (1<<6)) != 0
                or ((w[49]^w[51]) & (1<<6)) != 0
                or ((w[37]^(w[37]>>5)) & (1<<1)) != 0
                or ((w[35]^(w[39]>>25)) & (1<<5)) != 0
            ):
                mask &= ~_DV_I_51_2
        if (mask & _DV_I_52_0) != 0:
            mask &= ((((w[38]^w[39])<<11)) | ~_DV_I_52_0)
        if (mask & _DV_II_46_2) != 0:
            mask &= ((((w[47]^w[51])<<17)) | ~_DV_II_46_2)
        if (mask & _DV_II_48_0) != 0:
            if (
                ((w[36]^(w[40]>>25)) & (1<<3)) != 0
                or ((w[35]^(w[40]<<2)) & (1<<30)) == 0
            ):
                mask &= ~_DV_II_48_0
        if (mask & _DV_II_49_0) != 0:
            if (
                ((w[37]^(w[41]>>25)) & (1<<3)) != 0
                or ((w[36]^(w[41]<<2)) & (1<<30)) == 0
            ):
                mask &= ~_DV_II_49_0
        if (mask & _DV_II_49_2) != 0:
            if (
                ((w[53]^(w[54]<<5)) & (1<<6)) != 0
                or ((w[51]^w[53]) & (1<<6)) != 0
                or ((w[50]^w[54]) & (1<<1)) == 0
                or ((w[45]^(w[46]<<5)) & (1<<6)) != 0
                or ((w[37]^(w[41]>>25)) & (1<<5)) != 0
                or ((w[36]^(w[41]>>30)) & (1<<0)) == 0
            ):
                mask &= ~_DV_II_49_2
        if (mask & _DV_II_50_0) != 0:
            if (
                ((w[55]^w[58]) & (1<<29)) == 0
                or ((w[38]^(w[42]>>25)) & (1<<3)) != 0
                or ((w[37]^(w[42]<<2)) & (1<<30)) == 0
            ):
                mask &= ~_DV_II_50_0
        if (mask & _DV_II_50_2) != 0:
            if (
                ((w[54]^(w[55]<<5)) & (1<<6)) != 0
                or ((w[52]^w[54]) & (1<<6)) != 0
                or ((w[51]^w[55]) & (1<<1)) == 0
                or ((w[45]^w[47]) & (1<<1)) == 0
                or ((w[38]^(w[42]>>25)) & (1<<5)) != 0
                or ((w[37]^(w[42]>>30)) & (1<<0)) == 0
            ):
                mask &= ~_DV_II_50_2
        if (mask & _DV_II_51_0) != 0:
            if (
                ((w[39]^(w[43]>>25)) & (1<<3)) != 0
                or ((w[38]^(w[43]<<2)) & (1<<30)) == 0
            ):
                mask &= ~_DV_II_51_0
        if (mask & _DV_II_51_2) != 0:
            if (
                ((w[55]^(w[56]<<5)) & (1<<6)) != 0
                or ((w[53]^w[55]) & (1<<6)) != 0
                or ((w[52]^w[56]) & (1<<1)) == 0
                or ((w[46]^w[48]) & (1<<1)) == 0
                or ((w[39]^(w[43]>>25)) & (1<<5)) != 0
                or ((w[38]^(w[43]>>30)) & (1<<0)) == 0
            ):
                mask &= ~_DV_II_51_2
        if (mask & _DV_II_52_0) != 0:
            if (
                ((w[59]^w[60]) & (1<<29)) != 0
                or ((w[40]^(w[44]>>25)) & (1<<3)) != 0
                or ((w[40]^(w[44]>>25)) & (1<<4)) != 0
                or ((w[39]^(w[44]<<2)) & (1<<30)) == 0
            ):
                mask &= ~_DV_II_52_0
        if (mask & _DV_II_53_0) != 0:
            if (
                ((w[58]^w[61]) & (1<<29)) == 0
                or ((w[57]^(w[61]>>25)) & (1<<4)) != 0
                or ((w[41]^(w[45]>>25)) & (1<<3)) != 0
                or ((w[41]^(w[45]>>25)) & (1<<4)) != 0
            ):
                mask &= ~_DV_II_53_0
        if (mask & _DV_II_54_0) != 0:
            if (
                ((w[58]^(w[62]>>25)) & (1<<4)) != 0
                or ((w[42]^(w[46]>>25)) & (1<<3)) != 0
                or ((w[42]^(w[46]>>25)) & (1<<4)) != 0
            ):
                mask &= ~_DV_II_54_0
        if (mask & _DV_II_55_0) != 0:
            if (
                ((w[59]^(w[63]>>25)) & (1<<4)) != 0
                or ((w[57]^(w[59]>>25)) & (1<<4)) != 0
                or ((w[43]^(w[47]>>25)) & (1<<3)) != 0
                or ((w[43]^(w[47]>>25)) & (1<<4)) != 0
            ):
                mask &= ~_DV_II_55_0
        if (mask & _DV_II_56_0) != 0:
            if (
                ((w[60]^(w[64]>>25)) & (1<<4)) != 0
                or ((w[44]^(w[48]>>25)) & (1<<3)) != 0
                or ((w[44]^(w[48]>>25)) & (1<<4)) != 0
            ):
                mask &= ~_DV_II_56_0
    return mask
