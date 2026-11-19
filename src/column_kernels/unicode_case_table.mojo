"""⛔ GENERATED FILE -- DO NOT EDIT BY HAND.

The SIMPLE (1:1) Unicode case mapping that `upper()` / `lower()` implement,
MEASURED FROM `duckdb v1.5.3` ITSELF over every codepoint in
U+0001..U+10FFFF -- not transcribed from UnicodeData.txt, because the parity
target for this engine is DuckDB and a second source would be a second thing to
disagree with.

★ SIMPLE, NOT FULL, AND THAT IS MEASURED RATHER THAN ASSUMED. Over all
1,112,064 legal codepoints DuckDB returns exactly ONE codepoint for every
one-codepoint input, so `upper('ß')` is `'ẞ'` (U+1E9E) and NOT `'SS'`. That is
what lets the kernel in `unicode_case.mojo` be a 1:1 map with no expansion
buffer. The generator FAILS if that ever stops being true.

⚠ THE MAPPING IS NOT AN INVOLUTION AND IS NOT BYTE-LENGTH-PRESERVING. Both
facts are measured, both are DuckDB's behaviour, and both are load-bearing for
callers:
  * `lower(İ)` = `i` (U+0130 -> U+0069) and `upper(ı)` = `I` (U+0131 -> U+0049),
    so the Turkish dotted/dotless pair does NOT round-trip -- `upper(lower(İ))`
    is `I`, not `İ`. utf8proc's locale-independent mapping; DuckDB does the same.
  * `upper(ß)` = `ẞ` grows 2 bytes to 3; `upper(ı)` = `I` shrinks 2 bytes to 1.
    A caller assuming `len(upper(s)) == len(s)` is wrong on both.
"""

# fmt: off

def simple_upper_cp(cp: Int) -> Int:
    """The SIMPLE UPPERCASE mapping of one Unicode scalar value.

    GENERATED -- 201 ranges covering 1451 codepoints. Do not
    edit by hand; see this module's header for how it is generated.
    """
    # ASCII never enters the tree: it is the overwhelming majority of
    # real input and one compare answers it.
    if cp < 0x80:
        if cp >= 0x61 and cp <= 0x7A:
            return cp - 32
        return cp
    if cp < 0x03F1:
        if cp < 0x0253:
            if cp < 0x01B4:
                if cp < 0x0180:
                    if cp < 0x0131:
                        if cp < 0x00F8:
                            if cp < 0x00DF:
                                if cp < 0x00B5:
                                    return cp
                                if cp <= 0x00B5:
                                    return 0x039C
                                return cp
                            if cp <= 0x00DF:
                                return 0x1E9E
                            if cp < 0x00E0:
                                return cp
                            if cp <= 0x00F6:
                                return cp - 32
                            return cp
                        if cp <= 0x00FE:
                            return cp - 32
                        if cp < 0x0101:
                            if cp < 0x00FF:
                                return cp
                            if cp <= 0x00FF:
                                return 0x0178
                            return cp
                        if cp <= 0x012F:
                            if ((cp - 0x0101) & 1) == 0:
                                return cp - 1
                            return cp
                        return cp
                    if cp <= 0x0131:
                        return 0x0049
                    if cp < 0x014B:
                        if cp < 0x013A:
                            if cp < 0x0133:
                                return cp
                            if cp <= 0x0137:
                                if ((cp - 0x0133) & 1) == 0:
                                    return cp - 1
                                return cp
                            return cp
                        if cp <= 0x0148:
                            if ((cp - 0x013A) & 1) == 0:
                                return cp - 1
                            return cp
                        return cp
                    if cp <= 0x0177:
                        if ((cp - 0x014B) & 1) == 0:
                            return cp - 1
                        return cp
                    if cp < 0x017F:
                        if cp < 0x017A:
                            return cp
                        if cp <= 0x017E:
                            if ((cp - 0x017A) & 1) == 0:
                                return cp - 1
                            return cp
                        return cp
                    if cp <= 0x017F:
                        return 0x0053
                    return cp
                if cp <= 0x0180:
                    return 0x0243
                if cp < 0x019A:
                    if cp < 0x0192:
                        if cp < 0x0188:
                            if cp < 0x0183:
                                return cp
                            if cp <= 0x0185:
                                if ((cp - 0x0183) & 1) == 0:
                                    return cp - 1
                                return cp
                            return cp
                        if cp <= 0x0188:
                            return 0x0187
                        if cp < 0x018C:
                            return cp
                        if cp <= 0x018C:
                            return 0x018B
                        return cp
                    if cp <= 0x0192:
                        return 0x0191
                    if cp < 0x0199:
                        if cp < 0x0195:
                            return cp
                        if cp <= 0x0195:
                            return 0x01F6
                        return cp
                    if cp <= 0x0199:
                        return 0x0198
                    return cp
                if cp <= 0x019A:
                    return 0x023D
                if cp < 0x01A8:
                    if cp < 0x01A1:
                        if cp < 0x019E:
                            return cp
                        if cp <= 0x019E:
                            return 0x0220
                        return cp
                    if cp <= 0x01A5:
                        if ((cp - 0x01A1) & 1) == 0:
                            return cp - 1
                        return cp
                    return cp
                if cp <= 0x01A8:
                    return 0x01A7
                if cp < 0x01B0:
                    if cp < 0x01AD:
                        return cp
                    if cp <= 0x01AD:
                        return 0x01AC
                    return cp
                if cp <= 0x01B0:
                    return 0x01AF
                return cp
            if cp <= 0x01B6:
                if ((cp - 0x01B4) & 1) == 0:
                    return cp - 1
                return cp
            if cp < 0x01F2:
                if cp < 0x01C9:
                    if cp < 0x01C5:
                        if cp < 0x01BD:
                            if cp < 0x01B9:
                                return cp
                            if cp <= 0x01B9:
                                return 0x01B8
                            return cp
                        if cp <= 0x01BD:
                            return 0x01BC
                        if cp < 0x01BF:
                            return cp
                        if cp <= 0x01BF:
                            return 0x01F7
                        return cp
                    if cp <= 0x01C5:
                        return 0x01C4
                    if cp < 0x01C8:
                        if cp < 0x01C6:
                            return cp
                        if cp <= 0x01C6:
                            return 0x01C4
                        return cp
                    if cp <= 0x01C8:
                        return 0x01C7
                    return cp
                if cp <= 0x01C9:
                    return 0x01C7
                if cp < 0x01CE:
                    if cp < 0x01CC:
                        if cp < 0x01CB:
                            return cp
                        if cp <= 0x01CB:
                            return 0x01CA
                        return cp
                    if cp <= 0x01CC:
                        return 0x01CA
                    return cp
                if cp <= 0x01DC:
                    if ((cp - 0x01CE) & 1) == 0:
                        return cp - 1
                    return cp
                if cp < 0x01DF:
                    if cp < 0x01DD:
                        return cp
                    if cp <= 0x01DD:
                        return 0x018E
                    return cp
                if cp <= 0x01EF:
                    if ((cp - 0x01DF) & 1) == 0:
                        return cp - 1
                    return cp
                return cp
            if cp <= 0x01F2:
                return 0x01F1
            if cp < 0x023F:
                if cp < 0x01F9:
                    if cp < 0x01F5:
                        if cp < 0x01F3:
                            return cp
                        if cp <= 0x01F3:
                            return 0x01F1
                        return cp
                    if cp <= 0x01F5:
                        return 0x01F4
                    return cp
                if cp <= 0x021F:
                    if ((cp - 0x01F9) & 1) == 0:
                        return cp - 1
                    return cp
                if cp < 0x023C:
                    if cp < 0x0223:
                        return cp
                    if cp <= 0x0233:
                        if ((cp - 0x0223) & 1) == 0:
                            return cp - 1
                        return cp
                    return cp
                if cp <= 0x023C:
                    return 0x023B
                return cp
            if cp <= 0x0240:
                return cp + 10815
            if cp < 0x0250:
                if cp < 0x0247:
                    if cp < 0x0242:
                        return cp
                    if cp <= 0x0242:
                        return 0x0241
                    return cp
                if cp <= 0x024F:
                    if ((cp - 0x0247) & 1) == 0:
                        return cp - 1
                    return cp
                return cp
            if cp <= 0x0250:
                return 0x2C6F
            if cp < 0x0252:
                if cp < 0x0251:
                    return cp
                if cp <= 0x0251:
                    return 0x2C6D
                return cp
            if cp <= 0x0252:
                return 0x2C70
            return cp
        if cp <= 0x0253:
            return 0x0181
        if cp < 0x0288:
            if cp < 0x026A:
                if cp < 0x0261:
                    if cp < 0x025B:
                        if cp < 0x0256:
                            if cp < 0x0254:
                                return cp
                            if cp <= 0x0254:
                                return 0x0186
                            return cp
                        if cp <= 0x0257:
                            return cp - 205
                        if cp < 0x0259:
                            return cp
                        if cp <= 0x0259:
                            return 0x018F
                        return cp
                    if cp <= 0x025B:
                        return 0x0190
                    if cp < 0x0260:
                        if cp < 0x025C:
                            return cp
                        if cp <= 0x025C:
                            return 0xA7AB
                        return cp
                    if cp <= 0x0260:
                        return 0x0193
                    return cp
                if cp <= 0x0261:
                    return 0xA7AC
                if cp < 0x0266:
                    if cp < 0x0265:
                        if cp < 0x0263:
                            return cp
                        if cp <= 0x0263:
                            return 0x0194
                        return cp
                    if cp <= 0x0265:
                        return 0xA78D
                    return cp
                if cp <= 0x0266:
                    return 0xA7AA
                if cp < 0x0269:
                    if cp < 0x0268:
                        return cp
                    if cp <= 0x0268:
                        return 0x0197
                    return cp
                if cp <= 0x0269:
                    return 0x0196
                return cp
            if cp <= 0x026A:
                return 0xA7AE
            if cp < 0x0275:
                if cp < 0x026F:
                    if cp < 0x026C:
                        if cp < 0x026B:
                            return cp
                        if cp <= 0x026B:
                            return 0x2C62
                        return cp
                    if cp <= 0x026C:
                        return 0xA7AD
                    return cp
                if cp <= 0x026F:
                    return 0x019C
                if cp < 0x0272:
                    if cp < 0x0271:
                        return cp
                    if cp <= 0x0271:
                        return 0x2C6E
                    return cp
                if cp <= 0x0272:
                    return 0x019D
                return cp
            if cp <= 0x0275:
                return 0x019F
            if cp < 0x0282:
                if cp < 0x0280:
                    if cp < 0x027D:
                        return cp
                    if cp <= 0x027D:
                        return 0x2C64
                    return cp
                if cp <= 0x0280:
                    return 0x01A6
                return cp
            if cp <= 0x0282:
                return 0xA7C5
            if cp < 0x0287:
                if cp < 0x0283:
                    return cp
                if cp <= 0x0283:
                    return 0x01A9
                return cp
            if cp <= 0x0287:
                return 0xA7B1
            return cp
        if cp <= 0x0288:
            return 0x01AE
        if cp < 0x03B1:
            if cp < 0x0345:
                if cp < 0x0292:
                    if cp < 0x028A:
                        if cp < 0x0289:
                            return cp
                        if cp <= 0x0289:
                            return 0x0244
                        return cp
                    if cp <= 0x028B:
                        return cp - 217
                    if cp < 0x028C:
                        return cp
                    if cp <= 0x028C:
                        return 0x0245
                    return cp
                if cp <= 0x0292:
                    return 0x01B7
                if cp < 0x029E:
                    if cp < 0x029D:
                        return cp
                    if cp <= 0x029D:
                        return 0xA7B2
                    return cp
                if cp <= 0x029E:
                    return 0xA7B0
                return cp
            if cp <= 0x0345:
                return 0x0399
            if cp < 0x037B:
                if cp < 0x0377:
                    if cp < 0x0371:
                        return cp
                    if cp <= 0x0373:
                        if ((cp - 0x0371) & 1) == 0:
                            return cp - 1
                        return cp
                    return cp
                if cp <= 0x0377:
                    return 0x0376
                return cp
            if cp <= 0x037D:
                return cp + 130
            if cp < 0x03AD:
                if cp < 0x03AC:
                    return cp
                if cp <= 0x03AC:
                    return 0x0386
                return cp
            if cp <= 0x03AF:
                return cp - 37
            return cp
        if cp <= 0x03C1:
            return cp - 32
        if cp < 0x03D1:
            if cp < 0x03CC:
                if cp < 0x03C3:
                    if cp < 0x03C2:
                        return cp
                    if cp <= 0x03C2:
                        return 0x03A3
                    return cp
                if cp <= 0x03CB:
                    return cp - 32
                return cp
            if cp <= 0x03CC:
                return 0x038C
            if cp < 0x03D0:
                if cp < 0x03CD:
                    return cp
                if cp <= 0x03CE:
                    return cp - 63
                return cp
            if cp <= 0x03D0:
                return 0x0392
            return cp
        if cp <= 0x03D1:
            return 0x0398
        if cp < 0x03D7:
            if cp < 0x03D6:
                if cp < 0x03D5:
                    return cp
                if cp <= 0x03D5:
                    return 0x03A6
                return cp
            if cp <= 0x03D6:
                return 0x03A0
            return cp
        if cp <= 0x03D7:
            return 0x03CF
        if cp < 0x03F0:
            if cp < 0x03D9:
                return cp
            if cp <= 0x03EF:
                if ((cp - 0x03D9) & 1) == 0:
                    return cp - 1
                return cp
            return cp
        if cp <= 0x03F0:
            return 0x039A
        return cp
    if cp <= 0x03F1:
        return 0x03A1
    if cp < 0x1FC3:
        if cp < 0x1D79:
            if cp < 0x0561:
                if cp < 0x0450:
                    if cp < 0x03F8:
                        if cp < 0x03F3:
                            if cp < 0x03F2:
                                return cp
                            if cp <= 0x03F2:
                                return 0x03F9
                            return cp
                        if cp <= 0x03F3:
                            return 0x037F
                        if cp < 0x03F5:
                            return cp
                        if cp <= 0x03F5:
                            return 0x0395
                        return cp
                    if cp <= 0x03F8:
                        return 0x03F7
                    if cp < 0x0430:
                        if cp < 0x03FB:
                            return cp
                        if cp <= 0x03FB:
                            return 0x03FA
                        return cp
                    if cp <= 0x044F:
                        return cp - 32
                    return cp
                if cp <= 0x045F:
                    return cp - 80
                if cp < 0x04C2:
                    if cp < 0x048B:
                        if cp < 0x0461:
                            return cp
                        if cp <= 0x0481:
                            if ((cp - 0x0461) & 1) == 0:
                                return cp - 1
                            return cp
                        return cp
                    if cp <= 0x04BF:
                        if ((cp - 0x048B) & 1) == 0:
                            return cp - 1
                        return cp
                    return cp
                if cp <= 0x04CE:
                    if ((cp - 0x04C2) & 1) == 0:
                        return cp - 1
                    return cp
                if cp < 0x04D1:
                    if cp < 0x04CF:
                        return cp
                    if cp <= 0x04CF:
                        return 0x04C0
                    return cp
                if cp <= 0x052F:
                    if ((cp - 0x04D1) & 1) == 0:
                        return cp - 1
                    return cp
                return cp
            if cp <= 0x0586:
                return cp - 48
            if cp < 0x1C82:
                if cp < 0x13F8:
                    if cp < 0x10FD:
                        if cp < 0x10D0:
                            return cp
                        if cp <= 0x10FA:
                            return cp + 3008
                        return cp
                    if cp <= 0x10FF:
                        return cp + 3008
                    return cp
                if cp <= 0x13FD:
                    return cp - 8
                if cp < 0x1C81:
                    if cp < 0x1C80:
                        return cp
                    if cp <= 0x1C80:
                        return 0x0412
                    return cp
                if cp <= 0x1C81:
                    return 0x0414
                return cp
            if cp <= 0x1C82:
                return 0x041E
            if cp < 0x1C86:
                if cp < 0x1C85:
                    if cp < 0x1C83:
                        return cp
                    if cp <= 0x1C84:
                        return cp - 6242
                    return cp
                if cp <= 0x1C85:
                    return 0x0422
                return cp
            if cp <= 0x1C86:
                return 0x042A
            if cp < 0x1C88:
                if cp < 0x1C87:
                    return cp
                if cp <= 0x1C87:
                    return 0x0462
                return cp
            if cp <= 0x1C88:
                return 0xA64A
            return cp
        if cp <= 0x1D79:
            return 0xA77D
        if cp < 0x1F70:
            if cp < 0x1F10:
                if cp < 0x1E9B:
                    if cp < 0x1D8E:
                        if cp < 0x1D7D:
                            return cp
                        if cp <= 0x1D7D:
                            return 0x2C63
                        return cp
                    if cp <= 0x1D8E:
                        return 0xA7C6
                    if cp < 0x1E01:
                        return cp
                    if cp <= 0x1E95:
                        if ((cp - 0x1E01) & 1) == 0:
                            return cp - 1
                        return cp
                    return cp
                if cp <= 0x1E9B:
                    return 0x1E60
                if cp < 0x1F00:
                    if cp < 0x1EA1:
                        return cp
                    if cp <= 0x1EFF:
                        if ((cp - 0x1EA1) & 1) == 0:
                            return cp - 1
                        return cp
                    return cp
                if cp <= 0x1F07:
                    return cp + 8
                return cp
            if cp <= 0x1F15:
                return cp + 8
            if cp < 0x1F40:
                if cp < 0x1F30:
                    if cp < 0x1F20:
                        return cp
                    if cp <= 0x1F27:
                        return cp + 8
                    return cp
                if cp <= 0x1F37:
                    return cp + 8
                return cp
            if cp <= 0x1F45:
                return cp + 8
            if cp < 0x1F60:
                if cp < 0x1F51:
                    return cp
                if cp <= 0x1F57:
                    if ((cp - 0x1F51) & 1) == 0:
                        return cp + 8
                    return cp
                return cp
            if cp <= 0x1F67:
                return cp + 8
            return cp
        if cp <= 0x1F71:
            return cp + 74
        if cp < 0x1F80:
            if cp < 0x1F78:
                if cp < 0x1F76:
                    if cp < 0x1F72:
                        return cp
                    if cp <= 0x1F75:
                        return cp + 86
                    return cp
                if cp <= 0x1F77:
                    return cp + 100
                return cp
            if cp <= 0x1F79:
                return cp + 128
            if cp < 0x1F7C:
                if cp < 0x1F7A:
                    return cp
                if cp <= 0x1F7B:
                    return cp + 112
                return cp
            if cp <= 0x1F7D:
                return cp + 126
            return cp
        if cp <= 0x1F87:
            return cp + 8
        if cp < 0x1FB0:
            if cp < 0x1FA0:
                if cp < 0x1F90:
                    return cp
                if cp <= 0x1F97:
                    return cp + 8
                return cp
            if cp <= 0x1FA7:
                return cp + 8
            return cp
        if cp <= 0x1FB1:
            return cp + 8
        if cp < 0x1FBE:
            if cp < 0x1FB3:
                return cp
            if cp <= 0x1FB3:
                return 0x1FBC
            return cp
        if cp <= 0x1FBE:
            return 0x0399
        return cp
    if cp <= 0x1FC3:
        return 0x1FCC
    if cp < 0xA733:
        if cp < 0x2C68:
            if cp < 0x2184:
                if cp < 0x1FF3:
                    if cp < 0x1FE0:
                        if cp < 0x1FD0:
                            return cp
                        if cp <= 0x1FD1:
                            return cp + 8
                        return cp
                    if cp <= 0x1FE1:
                        return cp + 8
                    if cp < 0x1FE5:
                        return cp
                    if cp <= 0x1FE5:
                        return 0x1FEC
                    return cp
                if cp <= 0x1FF3:
                    return 0x1FFC
                if cp < 0x2170:
                    if cp < 0x214E:
                        return cp
                    if cp <= 0x214E:
                        return 0x2132
                    return cp
                if cp <= 0x217F:
                    return cp - 16
                return cp
            if cp <= 0x2184:
                return 0x2183
            if cp < 0x2C61:
                if cp < 0x2C30:
                    if cp < 0x24D0:
                        return cp
                    if cp <= 0x24E9:
                        return cp - 26
                    return cp
                if cp <= 0x2C5F:
                    return cp - 48
                return cp
            if cp <= 0x2C61:
                return 0x2C60
            if cp < 0x2C66:
                if cp < 0x2C65:
                    return cp
                if cp <= 0x2C65:
                    return 0x023A
                return cp
            if cp <= 0x2C66:
                return 0x023E
            return cp
        if cp <= 0x2C6C:
            if ((cp - 0x2C68) & 1) == 0:
                return cp - 1
            return cp
        if cp < 0x2D00:
            if cp < 0x2C81:
                if cp < 0x2C76:
                    if cp < 0x2C73:
                        return cp
                    if cp <= 0x2C73:
                        return 0x2C72
                    return cp
                if cp <= 0x2C76:
                    return 0x2C75
                return cp
            if cp <= 0x2CE3:
                if ((cp - 0x2C81) & 1) == 0:
                    return cp - 1
                return cp
            if cp < 0x2CF3:
                if cp < 0x2CEC:
                    return cp
                if cp <= 0x2CEE:
                    if ((cp - 0x2CEC) & 1) == 0:
                        return cp - 1
                    return cp
                return cp
            if cp <= 0x2CF3:
                return 0x2CF2
            return cp
        if cp <= 0x2D25:
            return cp - 7264
        if cp < 0xA641:
            if cp < 0x2D2D:
                if cp < 0x2D27:
                    return cp
                if cp <= 0x2D27:
                    return 0x10C7
                return cp
            if cp <= 0x2D2D:
                return 0x10CD
            return cp
        if cp <= 0xA66D:
            if ((cp - 0xA641) & 1) == 0:
                return cp - 1
            return cp
        if cp < 0xA723:
            if cp < 0xA681:
                return cp
            if cp <= 0xA69B:
                if ((cp - 0xA681) & 1) == 0:
                    return cp - 1
                return cp
            return cp
        if cp <= 0xA72F:
            if ((cp - 0xA723) & 1) == 0:
                return cp - 1
            return cp
        return cp
    if cp <= 0xA76F:
        if ((cp - 0xA733) & 1) == 0:
            return cp - 1
        return cp
    if cp < 0xAB70:
        if cp < 0xA7B5:
            if cp < 0xA791:
                if cp < 0xA77F:
                    if cp < 0xA77A:
                        return cp
                    if cp <= 0xA77C:
                        if ((cp - 0xA77A) & 1) == 0:
                            return cp - 1
                        return cp
                    return cp
                if cp <= 0xA787:
                    if ((cp - 0xA77F) & 1) == 0:
                        return cp - 1
                    return cp
                if cp < 0xA78C:
                    return cp
                if cp <= 0xA78C:
                    return 0xA78B
                return cp
            if cp <= 0xA793:
                if ((cp - 0xA791) & 1) == 0:
                    return cp - 1
                return cp
            if cp < 0xA797:
                if cp < 0xA794:
                    return cp
                if cp <= 0xA794:
                    return 0xA7C4
                return cp
            if cp <= 0xA7A9:
                if ((cp - 0xA797) & 1) == 0:
                    return cp - 1
                return cp
            return cp
        if cp <= 0xA7C3:
            if ((cp - 0xA7B5) & 1) == 0:
                return cp - 1
            return cp
        if cp < 0xA7D7:
            if cp < 0xA7D1:
                if cp < 0xA7C8:
                    return cp
                if cp <= 0xA7CA:
                    if ((cp - 0xA7C8) & 1) == 0:
                        return cp - 1
                    return cp
                return cp
            if cp <= 0xA7D1:
                return 0xA7D0
            return cp
        if cp <= 0xA7D9:
            if ((cp - 0xA7D7) & 1) == 0:
                return cp - 1
            return cp
        if cp < 0xAB53:
            if cp < 0xA7F6:
                return cp
            if cp <= 0xA7F6:
                return 0xA7F5
            return cp
        if cp <= 0xAB53:
            return 0xA7B3
        return cp
    if cp <= 0xABBF:
        return cp - 38864
    if cp < 0x105B3:
        if cp < 0x104D8:
            if cp < 0x10428:
                if cp < 0xFF41:
                    return cp
                if cp <= 0xFF5A:
                    return cp - 32
                return cp
            if cp <= 0x1044F:
                return cp - 40
            return cp
        if cp <= 0x104FB:
            return cp - 40
        if cp < 0x105A3:
            if cp < 0x10597:
                return cp
            if cp <= 0x105A1:
                return cp - 39
            return cp
        if cp <= 0x105B1:
            return cp - 39
        return cp
    if cp <= 0x105B9:
        return cp - 39
    if cp < 0x118C0:
        if cp < 0x10CC0:
            if cp < 0x105BB:
                return cp
            if cp <= 0x105BC:
                return cp - 39
            return cp
        if cp <= 0x10CF2:
            return cp - 64
        return cp
    if cp <= 0x118DF:
        return cp - 32
    if cp < 0x1E922:
        if cp < 0x16E60:
            return cp
        if cp <= 0x16E7F:
            return cp - 32
        return cp
    if cp <= 0x1E943:
        return cp - 34
    return cp


def simple_lower_cp(cp: Int) -> Int:
    """The SIMPLE LOWERCASE mapping of one Unicode scalar value.

    GENERATED -- 182 ranges covering 1433 codepoints. Do not
    edit by hand; see this module's header for how it is generated.
    """
    # ASCII never enters the tree: it is the overwhelming majority of
    # real input and one compare answers it.
    if cp < 0x80:
        if cp >= 0x41 and cp <= 0x5A:
            return cp + 32
        return cp
    if cp < 0x13F0:
        if cp < 0x01DE:
            if cp < 0x0197:
                if cp < 0x0186:
                    if cp < 0x0139:
                        if cp < 0x0100:
                            if cp < 0x00D8:
                                if cp < 0x00C0:
                                    return cp
                                if cp <= 0x00D6:
                                    return cp + 32
                                return cp
                            if cp <= 0x00DE:
                                return cp + 32
                            return cp
                        if cp <= 0x012E:
                            if ((cp - 0x0100) & 1) == 0:
                                return cp + 1
                            return cp
                        if cp < 0x0132:
                            if cp < 0x0130:
                                return cp
                            if cp <= 0x0130:
                                return 0x0069
                            return cp
                        if cp <= 0x0136:
                            if ((cp - 0x0132) & 1) == 0:
                                return cp + 1
                            return cp
                        return cp
                    if cp <= 0x0147:
                        if ((cp - 0x0139) & 1) == 0:
                            return cp + 1
                        return cp
                    if cp < 0x0179:
                        if cp < 0x0178:
                            if cp < 0x014A:
                                return cp
                            if cp <= 0x0176:
                                if ((cp - 0x014A) & 1) == 0:
                                    return cp + 1
                                return cp
                            return cp
                        if cp <= 0x0178:
                            return 0x00FF
                        return cp
                    if cp <= 0x017D:
                        if ((cp - 0x0179) & 1) == 0:
                            return cp + 1
                        return cp
                    if cp < 0x0182:
                        if cp < 0x0181:
                            return cp
                        if cp <= 0x0181:
                            return 0x0253
                        return cp
                    if cp <= 0x0184:
                        if ((cp - 0x0182) & 1) == 0:
                            return cp + 1
                        return cp
                    return cp
                if cp <= 0x0186:
                    return 0x0254
                if cp < 0x0190:
                    if cp < 0x018B:
                        if cp < 0x0189:
                            if cp < 0x0187:
                                return cp
                            if cp <= 0x0187:
                                return 0x0188
                            return cp
                        if cp <= 0x018A:
                            return cp + 205
                        return cp
                    if cp <= 0x018B:
                        return 0x018C
                    if cp < 0x018F:
                        if cp < 0x018E:
                            return cp
                        if cp <= 0x018E:
                            return 0x01DD
                        return cp
                    if cp <= 0x018F:
                        return 0x0259
                    return cp
                if cp <= 0x0190:
                    return 0x025B
                if cp < 0x0194:
                    if cp < 0x0193:
                        if cp < 0x0191:
                            return cp
                        if cp <= 0x0191:
                            return 0x0192
                        return cp
                    if cp <= 0x0193:
                        return 0x0260
                    return cp
                if cp <= 0x0194:
                    return 0x0263
                if cp < 0x0196:
                    return cp
                if cp <= 0x0196:
                    return 0x0269
                return cp
            if cp <= 0x0197:
                return 0x0268
            if cp < 0x01B1:
                if cp < 0x01A6:
                    if cp < 0x019D:
                        if cp < 0x019C:
                            if cp < 0x0198:
                                return cp
                            if cp <= 0x0198:
                                return 0x0199
                            return cp
                        if cp <= 0x019C:
                            return 0x026F
                        return cp
                    if cp <= 0x019D:
                        return 0x0272
                    if cp < 0x01A0:
                        if cp < 0x019F:
                            return cp
                        if cp <= 0x019F:
                            return 0x0275
                        return cp
                    if cp <= 0x01A4:
                        if ((cp - 0x01A0) & 1) == 0:
                            return cp + 1
                        return cp
                    return cp
                if cp <= 0x01A6:
                    return 0x0280
                if cp < 0x01AC:
                    if cp < 0x01A9:
                        if cp < 0x01A7:
                            return cp
                        if cp <= 0x01A7:
                            return 0x01A8
                        return cp
                    if cp <= 0x01A9:
                        return 0x0283
                    return cp
                if cp <= 0x01AC:
                    return 0x01AD
                if cp < 0x01AF:
                    if cp < 0x01AE:
                        return cp
                    if cp <= 0x01AE:
                        return 0x0288
                    return cp
                if cp <= 0x01AF:
                    return 0x01B0
                return cp
            if cp <= 0x01B2:
                return cp + 217
            if cp < 0x01C5:
                if cp < 0x01B8:
                    if cp < 0x01B7:
                        if cp < 0x01B3:
                            return cp
                        if cp <= 0x01B5:
                            if ((cp - 0x01B3) & 1) == 0:
                                return cp + 1
                            return cp
                        return cp
                    if cp <= 0x01B7:
                        return 0x0292
                    return cp
                if cp <= 0x01B8:
                    return 0x01B9
                if cp < 0x01C4:
                    if cp < 0x01BC:
                        return cp
                    if cp <= 0x01BC:
                        return 0x01BD
                    return cp
                if cp <= 0x01C4:
                    return 0x01C6
                return cp
            if cp <= 0x01C5:
                return 0x01C6
            if cp < 0x01CA:
                if cp < 0x01C8:
                    if cp < 0x01C7:
                        return cp
                    if cp <= 0x01C7:
                        return 0x01C9
                    return cp
                if cp <= 0x01C8:
                    return 0x01C9
                return cp
            if cp <= 0x01CA:
                return 0x01CC
            if cp < 0x01CB:
                return cp
            if cp <= 0x01DB:
                if ((cp - 0x01CB) & 1) == 0:
                    return cp + 1
                return cp
            return cp
        if cp <= 0x01EE:
            if ((cp - 0x01DE) & 1) == 0:
                return cp + 1
            return cp
        if cp < 0x038E:
            if cp < 0x0241:
                if cp < 0x0220:
                    if cp < 0x01F6:
                        if cp < 0x01F2:
                            if cp < 0x01F1:
                                return cp
                            if cp <= 0x01F1:
                                return 0x01F3
                            return cp
                        if cp <= 0x01F4:
                            if ((cp - 0x01F2) & 1) == 0:
                                return cp + 1
                            return cp
                        return cp
                    if cp <= 0x01F6:
                        return 0x0195
                    if cp < 0x01F8:
                        if cp < 0x01F7:
                            return cp
                        if cp <= 0x01F7:
                            return 0x01BF
                        return cp
                    if cp <= 0x021E:
                        if ((cp - 0x01F8) & 1) == 0:
                            return cp + 1
                        return cp
                    return cp
                if cp <= 0x0220:
                    return 0x019E
                if cp < 0x023B:
                    if cp < 0x023A:
                        if cp < 0x0222:
                            return cp
                        if cp <= 0x0232:
                            if ((cp - 0x0222) & 1) == 0:
                                return cp + 1
                            return cp
                        return cp
                    if cp <= 0x023A:
                        return 0x2C65
                    return cp
                if cp <= 0x023B:
                    return 0x023C
                if cp < 0x023E:
                    if cp < 0x023D:
                        return cp
                    if cp <= 0x023D:
                        return 0x019A
                    return cp
                if cp <= 0x023E:
                    return 0x2C66
                return cp
            if cp <= 0x0241:
                return 0x0242
            if cp < 0x0376:
                if cp < 0x0245:
                    if cp < 0x0244:
                        if cp < 0x0243:
                            return cp
                        if cp <= 0x0243:
                            return 0x0180
                        return cp
                    if cp <= 0x0244:
                        return 0x0289
                    return cp
                if cp <= 0x0245:
                    return 0x028C
                if cp < 0x0370:
                    if cp < 0x0246:
                        return cp
                    if cp <= 0x024E:
                        if ((cp - 0x0246) & 1) == 0:
                            return cp + 1
                        return cp
                    return cp
                if cp <= 0x0372:
                    if ((cp - 0x0370) & 1) == 0:
                        return cp + 1
                    return cp
                return cp
            if cp <= 0x0376:
                return 0x0377
            if cp < 0x0388:
                if cp < 0x0386:
                    if cp < 0x037F:
                        return cp
                    if cp <= 0x037F:
                        return 0x03F3
                    return cp
                if cp <= 0x0386:
                    return 0x03AC
                return cp
            if cp <= 0x038A:
                return cp + 37
            if cp < 0x038C:
                return cp
            if cp <= 0x038C:
                return 0x03CC
            return cp
        if cp <= 0x038F:
            return cp + 63
        if cp < 0x0410:
            if cp < 0x03F7:
                if cp < 0x03CF:
                    if cp < 0x03A3:
                        if cp < 0x0391:
                            return cp
                        if cp <= 0x03A1:
                            return cp + 32
                        return cp
                    if cp <= 0x03AB:
                        return cp + 32
                    return cp
                if cp <= 0x03CF:
                    return 0x03D7
                if cp < 0x03F4:
                    if cp < 0x03D8:
                        return cp
                    if cp <= 0x03EE:
                        if ((cp - 0x03D8) & 1) == 0:
                            return cp + 1
                        return cp
                    return cp
                if cp <= 0x03F4:
                    return 0x03B8
                return cp
            if cp <= 0x03F7:
                return 0x03F8
            if cp < 0x03FD:
                if cp < 0x03FA:
                    if cp < 0x03F9:
                        return cp
                    if cp <= 0x03F9:
                        return 0x03F2
                    return cp
                if cp <= 0x03FA:
                    return 0x03FB
                return cp
            if cp <= 0x03FF:
                return cp - 130
            if cp < 0x0400:
                return cp
            if cp <= 0x040F:
                return cp + 80
            return cp
        if cp <= 0x042F:
            return cp + 32
        if cp < 0x0531:
            if cp < 0x04C0:
                if cp < 0x048A:
                    if cp < 0x0460:
                        return cp
                    if cp <= 0x0480:
                        if ((cp - 0x0460) & 1) == 0:
                            return cp + 1
                        return cp
                    return cp
                if cp <= 0x04BE:
                    if ((cp - 0x048A) & 1) == 0:
                        return cp + 1
                    return cp
                return cp
            if cp <= 0x04C0:
                return 0x04CF
            if cp < 0x04D0:
                if cp < 0x04C1:
                    return cp
                if cp <= 0x04CD:
                    if ((cp - 0x04C1) & 1) == 0:
                        return cp + 1
                    return cp
                return cp
            if cp <= 0x052E:
                if ((cp - 0x04D0) & 1) == 0:
                    return cp + 1
                return cp
            return cp
        if cp <= 0x0556:
            return cp + 48
        if cp < 0x10CD:
            if cp < 0x10C7:
                if cp < 0x10A0:
                    return cp
                if cp <= 0x10C5:
                    return cp + 7264
                return cp
            if cp <= 0x10C7:
                return 0x2D27
            return cp
        if cp <= 0x10CD:
            return 0x2D2D
        if cp < 0x13A0:
            return cp
        if cp <= 0x13EF:
            return cp + 38864
        return cp
    if cp <= 0x13F5:
        return cp + 8
    if cp < 0x2C72:
        if cp < 0x1FE8:
            if cp < 0x1F68:
                if cp < 0x1F08:
                    if cp < 0x1E00:
                        if cp < 0x1CBD:
                            if cp < 0x1C90:
                                return cp
                            if cp <= 0x1CBA:
                                return cp - 3008
                            return cp
                        if cp <= 0x1CBF:
                            return cp - 3008
                        return cp
                    if cp <= 0x1E94:
                        if ((cp - 0x1E00) & 1) == 0:
                            return cp + 1
                        return cp
                    if cp < 0x1EA0:
                        if cp < 0x1E9E:
                            return cp
                        if cp <= 0x1E9E:
                            return 0x00DF
                        return cp
                    if cp <= 0x1EFE:
                        if ((cp - 0x1EA0) & 1) == 0:
                            return cp + 1
                        return cp
                    return cp
                if cp <= 0x1F0F:
                    return cp - 8
                if cp < 0x1F38:
                    if cp < 0x1F28:
                        if cp < 0x1F18:
                            return cp
                        if cp <= 0x1F1D:
                            return cp - 8
                        return cp
                    if cp <= 0x1F2F:
                        return cp - 8
                    return cp
                if cp <= 0x1F3F:
                    return cp - 8
                if cp < 0x1F59:
                    if cp < 0x1F48:
                        return cp
                    if cp <= 0x1F4D:
                        return cp - 8
                    return cp
                if cp <= 0x1F5F:
                    if ((cp - 0x1F59) & 1) == 0:
                        return cp - 8
                    return cp
                return cp
            if cp <= 0x1F6F:
                return cp - 8
            if cp < 0x1FBC:
                if cp < 0x1FA8:
                    if cp < 0x1F98:
                        if cp < 0x1F88:
                            return cp
                        if cp <= 0x1F8F:
                            return cp - 8
                        return cp
                    if cp <= 0x1F9F:
                        return cp - 8
                    return cp
                if cp <= 0x1FAF:
                    return cp - 8
                if cp < 0x1FBA:
                    if cp < 0x1FB8:
                        return cp
                    if cp <= 0x1FB9:
                        return cp - 8
                    return cp
                if cp <= 0x1FBB:
                    return cp - 74
                return cp
            if cp <= 0x1FBC:
                return 0x1FB3
            if cp < 0x1FD8:
                if cp < 0x1FCC:
                    if cp < 0x1FC8:
                        return cp
                    if cp <= 0x1FCB:
                        return cp - 86
                    return cp
                if cp <= 0x1FCC:
                    return 0x1FC3
                return cp
            if cp <= 0x1FD9:
                return cp - 8
            if cp < 0x1FDA:
                return cp
            if cp <= 0x1FDB:
                return cp - 100
            return cp
        if cp <= 0x1FE9:
            return cp - 8
        if cp < 0x24B6:
            if cp < 0x2126:
                if cp < 0x1FF8:
                    if cp < 0x1FEC:
                        if cp < 0x1FEA:
                            return cp
                        if cp <= 0x1FEB:
                            return cp - 112
                        return cp
                    if cp <= 0x1FEC:
                        return 0x1FE5
                    return cp
                if cp <= 0x1FF9:
                    return cp - 128
                if cp < 0x1FFC:
                    if cp < 0x1FFA:
                        return cp
                    if cp <= 0x1FFB:
                        return cp - 126
                    return cp
                if cp <= 0x1FFC:
                    return 0x1FF3
                return cp
            if cp <= 0x2126:
                return 0x03C9
            if cp < 0x2132:
                if cp < 0x212B:
                    if cp < 0x212A:
                        return cp
                    if cp <= 0x212A:
                        return 0x006B
                    return cp
                if cp <= 0x212B:
                    return 0x00E5
                return cp
            if cp <= 0x2132:
                return 0x214E
            if cp < 0x2183:
                if cp < 0x2160:
                    return cp
                if cp <= 0x216F:
                    return cp + 16
                return cp
            if cp <= 0x2183:
                return 0x2184
            return cp
        if cp <= 0x24CF:
            return cp + 26
        if cp < 0x2C67:
            if cp < 0x2C62:
                if cp < 0x2C60:
                    if cp < 0x2C00:
                        return cp
                    if cp <= 0x2C2F:
                        return cp + 48
                    return cp
                if cp <= 0x2C60:
                    return 0x2C61
                return cp
            if cp <= 0x2C62:
                return 0x026B
            if cp < 0x2C64:
                if cp < 0x2C63:
                    return cp
                if cp <= 0x2C63:
                    return 0x1D7D
                return cp
            if cp <= 0x2C64:
                return 0x027D
            return cp
        if cp <= 0x2C6B:
            if ((cp - 0x2C67) & 1) == 0:
                return cp + 1
            return cp
        if cp < 0x2C6F:
            if cp < 0x2C6E:
                if cp < 0x2C6D:
                    return cp
                if cp <= 0x2C6D:
                    return 0x0251
                return cp
            if cp <= 0x2C6E:
                return 0x0271
            return cp
        if cp <= 0x2C6F:
            return 0x0250
        if cp < 0x2C70:
            return cp
        if cp <= 0x2C70:
            return 0x0252
        return cp
    if cp <= 0x2C72:
        return 0x2C73
    if cp < 0xA7B1:
        if cp < 0xA77E:
            if cp < 0xA640:
                if cp < 0x2C80:
                    if cp < 0x2C7E:
                        if cp < 0x2C75:
                            return cp
                        if cp <= 0x2C75:
                            return 0x2C76
                        return cp
                    if cp <= 0x2C7F:
                        return cp - 10815
                    return cp
                if cp <= 0x2CE2:
                    if ((cp - 0x2C80) & 1) == 0:
                        return cp + 1
                    return cp
                if cp < 0x2CF2:
                    if cp < 0x2CEB:
                        return cp
                    if cp <= 0x2CED:
                        if ((cp - 0x2CEB) & 1) == 0:
                            return cp + 1
                        return cp
                    return cp
                if cp <= 0x2CF2:
                    return 0x2CF3
                return cp
            if cp <= 0xA66C:
                if ((cp - 0xA640) & 1) == 0:
                    return cp + 1
                return cp
            if cp < 0xA732:
                if cp < 0xA722:
                    if cp < 0xA680:
                        return cp
                    if cp <= 0xA69A:
                        if ((cp - 0xA680) & 1) == 0:
                            return cp + 1
                        return cp
                    return cp
                if cp <= 0xA72E:
                    if ((cp - 0xA722) & 1) == 0:
                        return cp + 1
                    return cp
                return cp
            if cp <= 0xA76E:
                if ((cp - 0xA732) & 1) == 0:
                    return cp + 1
                return cp
            if cp < 0xA77D:
                if cp < 0xA779:
                    return cp
                if cp <= 0xA77B:
                    if ((cp - 0xA779) & 1) == 0:
                        return cp + 1
                    return cp
                return cp
            if cp <= 0xA77D:
                return 0x1D79
            return cp
        if cp <= 0xA786:
            if ((cp - 0xA77E) & 1) == 0:
                return cp + 1
            return cp
        if cp < 0xA7AB:
            if cp < 0xA790:
                if cp < 0xA78D:
                    if cp < 0xA78B:
                        return cp
                    if cp <= 0xA78B:
                        return 0xA78C
                    return cp
                if cp <= 0xA78D:
                    return 0x0265
                return cp
            if cp <= 0xA792:
                if ((cp - 0xA790) & 1) == 0:
                    return cp + 1
                return cp
            if cp < 0xA7AA:
                if cp < 0xA796:
                    return cp
                if cp <= 0xA7A8:
                    if ((cp - 0xA796) & 1) == 0:
                        return cp + 1
                    return cp
                return cp
            if cp <= 0xA7AA:
                return 0x0266
            return cp
        if cp <= 0xA7AB:
            return 0x025C
        if cp < 0xA7AE:
            if cp < 0xA7AD:
                if cp < 0xA7AC:
                    return cp
                if cp <= 0xA7AC:
                    return 0x0261
                return cp
            if cp <= 0xA7AD:
                return 0x026C
            return cp
        if cp <= 0xA7AE:
            return 0x026A
        if cp < 0xA7B0:
            return cp
        if cp <= 0xA7B0:
            return 0x029E
        return cp
    if cp <= 0xA7B1:
        return 0x0287
    if cp < 0xFF21:
        if cp < 0xA7C6:
            if cp < 0xA7B4:
                if cp < 0xA7B3:
                    if cp < 0xA7B2:
                        return cp
                    if cp <= 0xA7B2:
                        return 0x029D
                    return cp
                if cp <= 0xA7B3:
                    return 0xAB53
                return cp
            if cp <= 0xA7C2:
                if ((cp - 0xA7B4) & 1) == 0:
                    return cp + 1
                return cp
            if cp < 0xA7C5:
                if cp < 0xA7C4:
                    return cp
                if cp <= 0xA7C4:
                    return 0xA794
                return cp
            if cp <= 0xA7C5:
                return 0x0282
            return cp
        if cp <= 0xA7C6:
            return 0x1D8E
        if cp < 0xA7D6:
            if cp < 0xA7D0:
                if cp < 0xA7C7:
                    return cp
                if cp <= 0xA7C9:
                    if ((cp - 0xA7C7) & 1) == 0:
                        return cp + 1
                    return cp
                return cp
            if cp <= 0xA7D0:
                return 0xA7D1
            return cp
        if cp <= 0xA7D8:
            if ((cp - 0xA7D6) & 1) == 0:
                return cp + 1
            return cp
        if cp < 0xA7F5:
            return cp
        if cp <= 0xA7F5:
            return 0xA7F6
        return cp
    if cp <= 0xFF3A:
        return cp + 32
    if cp < 0x10594:
        if cp < 0x10570:
            if cp < 0x104B0:
                if cp < 0x10400:
                    return cp
                if cp <= 0x10427:
                    return cp + 40
                return cp
            if cp <= 0x104D3:
                return cp + 40
            return cp
        if cp <= 0x1057A:
            return cp + 39
        if cp < 0x1058C:
            if cp < 0x1057C:
                return cp
            if cp <= 0x1058A:
                return cp + 39
            return cp
        if cp <= 0x10592:
            return cp + 39
        return cp
    if cp <= 0x10595:
        return cp + 39
    if cp < 0x16E40:
        if cp < 0x118A0:
            if cp < 0x10C80:
                return cp
            if cp <= 0x10CB2:
                return cp + 64
            return cp
        if cp <= 0x118BF:
            return cp + 32
        return cp
    if cp <= 0x16E5F:
        return cp + 32
    if cp < 0x1E900:
        return cp
    if cp <= 0x1E921:
        return cp + 34
    return cp
