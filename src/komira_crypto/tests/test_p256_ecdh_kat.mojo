# =============================================================================
# komira_crypto/tests/test_p256_ecdh_kat.mojo
# =============================================================================
#
# Known-answer tests for `p256_ecdh` (P-256 ECDH, SP 800-56A ECC CDH
# primitive). Every expected value is byte-exact from its source:
#
#   1. NIST CAVP KAS ECC CDH primitive test vectors, P-256 section, all 25
#      (COUNT 0-24 of KAS_ECC_CDH_PrimitiveTest.txt in ecccdhtestvectors.zip):
#      Z = x(dIUT * QCAVS). The vectors were cross-checked against the copy
#      AWS-LC ships in crypto/ecdh_extra/ecdh_tests.txt before being pasted.
#   2. RFC 5903 section 8.1 (256-bit random ECP group): both parties derive
#      girx.
#   3. RFC 8291 appendix A (Web Push): ECDH(ua_private, as_public) and
#      ECDH(as_private, ua_public) both equal ecdh_secret (the RFC's
#      base64url values, decoded to hex).
#
# A defect in the scalar multiply, the point decoding, or which coordinate is
# returned (x versus y) changes every expected value.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import hex_lower_array_32, p256_ecdh


def _nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return c - UInt8(0x61) + UInt8(10)
    raise Error("bad hex digit in a test vector")


def _hex(s: String) raises -> List[UInt8]:
    var bs = s.as_bytes()
    if len(bs) % 2 != 0:
        raise Error("odd-length hex in a test vector")
    var out = List[UInt8](capacity=len(bs) // 2)
    for i in range(len(bs) // 2):
        out.append((_nibble(bs[2 * i]) << UInt8(4)) | _nibble(bs[2 * i + 1]))
    return out^


def _check(label: String, priv: String, peer: String, want_z: String) raises:
    var d = _hex(priv)
    var q = _hex(peer)
    var z = p256_ecdh(Span(d), Span(q))
    assert_equal(hex_lower_array_32(z), want_z, label)


def _cavp(count: Int, d: String, qx: String, qy: String, z: String) raises:
    _check(
        String("CAVP P-256 COUNT ") + String(count), d, "04" + qx + qy, z
    )


def test_nist_cavp_kas_ecc_cdh_p256() raises:
    """All 25 P-256 vectors: Z = x(dIUT * QCAVS)."""
    _cavp(
        0,
        "7d7dc5f71eb29ddaf80d6214632eeae03d9058af1fb6d22ed80badb62bc1a534",
        "700c48f77f56584c5cc632ca65640db91b6bacce3a4df6b42ce7cc838833d287",
        "db71e509e3fd9b060ddb20ba5c51dcc5948d46fbf640dfe0441782cab85fa4ac",
        "46fc62106420ff012e54a434fbdd2d25ccc5852060561e68040dd7778997bd7b",
    )
    _cavp(
        1,
        "38f65d6dce47676044d58ce5139582d568f64bb16098d179dbab07741dd5caf5",
        "809f04289c64348c01515eb03d5ce7ac1a8cb9498f5caa50197e58d43a86a7ae",
        "b29d84e811197f25eba8f5194092cb6ff440e26d4421011372461f579271cda3",
        "057d636096cb80b67a8c038c890e887d1adfa4195e9b3ce241c8a778c59cda67",
    )
    _cavp(
        2,
        "1accfaf1b97712b85a6f54b148985a1bdc4c9bec0bd258cad4b3d603f49f32c8",
        "a2339c12d4a03c33546de533268b4ad667debf458b464d77443636440ee7fec3",
        "ef48a3ab26e20220bcda2c1851076839dae88eae962869a497bf73cb66faf536",
        "2d457b78b4614132477618a5b077965ec90730a8c81a1c75d6d4ec68005d67ec",
    )
    _cavp(
        3,
        "207c43a79bfee03db6f4b944f53d2fb76cc49ef1c9c4d34d51b6c65c4db6932d",
        "df3989b9fa55495719b3cf46dccd28b5153f7808191dd518eff0c3cff2b705ed",
        "422294ff46003429d739a33206c8752552c8ba54a270defc06e221e0feaf6ac4",
        "96441259534b80f6aee3d287a6bb17b5094dd4277d9e294f8fe73e48bf2a0024",
    )
    _cavp(
        4,
        "59137e38152350b195c9718d39673d519838055ad908dd4757152fd8255c09bf",
        "41192d2813e79561e6a1d6f53c8bc1a433a199c835e141b05a74a97b0faeb922",
        "1af98cc45e98a7e041b01cf35f462b7562281351c8ebf3ffa02e33a0722a1328",
        "19d44c8d63e8e8dd12c22a87b8cd4ece27acdde04dbf47f7f27537a6999a8e62",
    )
    _cavp(
        5,
        "f5f8e0174610a661277979b58ce5c90fee6c9b3bb346a90a7196255e40b132ef",
        "33e82092a0f1fb38f5649d5867fba28b503172b7035574bf8e5b7100a3052792",
        "f2cf6b601e0a05945e335550bf648d782f46186c772c0f20d3cd0d6b8ca14b2f",
        "664e45d5bba4ac931cd65d52017e4be9b19a515f669bea4703542a2c525cd3d3",
    )
    _cavp(
        6,
        "3b589af7db03459c23068b64f63f28d3c3c6bc25b5bf76ac05f35482888b5190",
        "6a9e0c3f916e4e315c91147be571686d90464e8bf981d34a90b6353bca6eeba7",
        "40f9bead39c2f2bcc2602f75b8a73ec7bdffcbcead159d0174c6c4d3c5357f05",
        "ca342daa50dc09d61be7c196c85e60a80c5cb04931746820be548cdde055679d",
    )
    _cavp(
        7,
        "d8bf929a20ea7436b2461b541a11c80e61d826c0a4c9d322b31dd54e7f58b9c8",
        "a9c0acade55c2a73ead1a86fb0a9713223c82475791cd0e210b046412ce224bb",
        "f6de0afa20e93e078467c053d241903edad734c6b403ba758c2b5ff04c9d4229",
        "35aa9b52536a461bfde4e85fc756be928c7de97923f0416c7a3ac8f88b3d4489",
    )
    _cavp(
        8,
        "0f9883ba0ef32ee75ded0d8bda39a5146a29f1f2507b3bd458dbea0b2bb05b4d",
        "94e94f16a98255fff2b9ac0c9598aac35487b3232d3231bd93b7db7df36f9eb9",
        "d8049a43579cfa90b8093a94416cbefbf93386f15b3f6e190b6e3455fedfe69a",
        "605c16178a9bc875dcbff54d63fe00df699c03e8a888e9e94dfbab90b25f39b4",
    )
    _cavp(
        9,
        "2beedb04b05c6988f6a67500bb813faf2cae0d580c9253b6339e4a3337bb6c08",
        "e099bf2a4d557460b5544430bbf6da11004d127cb5d67f64ab07c94fcdf5274f",
        "d9c50dbe70d714edb5e221f4e020610eeb6270517e688ca64fb0e98c7ef8c1c5",
        "f96e40a1b72840854bb62bc13c40cc2795e373d4e715980b261476835a092e0b",
    )
    _cavp(
        10,
        "77c15dcf44610e41696bab758943eff1409333e4d5a11bbe72c8f6c395e9f848",
        "f75a5fe56bda34f3c1396296626ef012dc07e4825838778a645c8248cff01658",
        "33bbdf1b1772d8059df568b061f3f1122f28a8d819167c97be448e3dc3fb0c3c",
        "8388fa79c4babdca02a8e8a34f9e43554976e420a4ad273c81b26e4228e9d3a3",
    )
    _cavp(
        11,
        "42a83b985011d12303db1a800f2610f74aa71cdf19c67d54ce6c9ed951e9093e",
        "2db4540d50230756158abf61d9835712b6486c74312183ccefcaef2797b7674d",
        "62f57f314e3f3495dc4e099012f5e0ba71770f9660a1eada54104cdfde77243e",
        "72877cea33ccc4715038d4bcbdfe0e43f42a9e2c0c3b017fc2370f4b9acbda4a",
    )
    _cavp(
        12,
        "ceed35507b5c93ead5989119b9ba342cfe38e6e638ba6eea343a55475de2800b",
        "cd94fc9497e8990750309e9a8534fd114b0a6e54da89c4796101897041d14ecb",
        "c3def4b5fe04faee0a11932229fff563637bfdee0e79c6deeaf449f85401c5c4",
        "e4e7408d85ff0e0e9c838003f28cdbd5247cdce31f32f62494b70e5f1bc36307",
    )
    _cavp(
        13,
        "43e0e9d95af4dc36483cdd1968d2b7eeb8611fcce77f3a4e7d059ae43e509604",
        "15b9e467af4d290c417402e040426fe4cf236bae72baa392ed89780dfccdb471",
        "cdf4e9170fb904302b8fd93a820ba8cc7ed4efd3a6f2d6b05b80b2ff2aee4e77",
        "ed56bcf695b734142c24ecb1fc1bb64d08f175eb243a31f37b3d9bb4407f3b96",
    )
    _cavp(
        14,
        "b2f3600df3368ef8a0bb85ab22f41fc0e5f4fdd54be8167a5c3cd4b08db04903",
        "49c503ba6c4fa605182e186b5e81113f075bc11dcfd51c932fb21e951eee2fa1",
        "8af706ff0922d87b3f0c5e4e31d8b259aeb260a9269643ed520a13bb25da5924",
        "bc5c7055089fc9d6c89f83c1ea1ada879d9934b2ea28fcf4e4a7e984b28ad2cf",
    )
    _cavp(
        15,
        "4002534307f8b62a9bf67ff641ddc60fef593b17c3341239e95bdb3e579bfdc8",
        "19b38de39fdd2f70f7091631a4f75d1993740ba9429162c2a45312401636b29c",
        "09aed7232b28e060941741b6828bcdfa2bc49cc844f3773611504f82a390a5ae",
        "9a4e8e657f6b0e097f47954a63c75d74fcba71a30d83651e3e5a91aa7ccd8343",
    )
    _cavp(
        16,
        "4dfa12defc60319021b681b3ff84a10a511958c850939ed45635934ba4979147",
        "2c91c61f33adfe9311c942fdbff6ba47020feff416b7bb63cec13faf9b099954",
        "6cab31b06419e5221fca014fb84ec870622a1b12bab5ae43682aa7ea73ea08d0",
        "3ca1fc7ad858fb1a6aba232542f3e2a749ffc7203a2374a3f3d3267f1fc97b78",
    )
    _cavp(
        17,
        "1331f6d874a4ed3bc4a2c6e9c74331d3039796314beee3b7152fcdba5556304e",
        "a28a2edf58025668f724aaf83a50956b7ac1cfbbff79b08c3bf87dfd2828d767",
        "dfa7bfffd4c766b86abeaf5c99b6e50cb9ccc9d9d00b7ffc7804b0491b67bc03",
        "1aaabe7ee6e4a6fa732291202433a237df1b49bc53866bfbe00db96a0f58224f",
    )
    _cavp(
        18,
        "dd5e9f70ae740073ca0204df60763fb6036c45709bf4a7bb4e671412fad65da3",
        "a2ef857a081f9d6eb206a81c4cf78a802bdf598ae380c8886ecd85fdc1ed7644",
        "563c4c20419f07bc17d0539fade1855e34839515b892c0f5d26561f97fa04d1a",
        "430e6a4fba4449d700d2733e557f66a3bf3d50517c1271b1ddae1161b7ac798c",
    )
    _cavp(
        19,
        "5ae026cfc060d55600717e55b8a12e116d1d0df34af831979057607c2d9c2f76",
        "ccd8a2d86bc92f2e01bce4d6922cf7fe1626aed044685e95e2eebd464505f01f",
        "e9ddd583a9635a667777d5b8a8f31b0f79eba12c75023410b54b8567dddc0f38",
        "1ce9e6740529499f98d1f1d71329147a33df1d05e4765b539b11cf615d6974d3",
    )
    _cavp(
        20,
        "b601ac425d5dbf9e1735c5e2d5bdb79ca98b3d5be4a2cfd6f2273f150e064d9d",
        "c188ffc8947f7301fb7b53e36746097c2134bf9cc981ba74b4e9c4361f595e4e",
        "bf7d2f2056e72421ef393f0c0f2b0e00130e3cac4abbcc00286168e85ec55051",
        "4690e3743c07d643f1bc183636ab2a9cb936a60a802113c49bb1b3f2d0661660",
    )
    _cavp(
        21,
        "fefb1dda1845312b5fce6b81b2be205af2f3a274f5a212f66c0d9fc33d7ae535",
        "317e1020ff53fccef18bf47bb7f2dd7707fb7b7a7578e04f35b3beed222a0eb6",
        "09420ce5a19d77c6fe1ee587e6a49fbaf8f280e8df033d75403302e5a27db2ae",
        "30c2261bd0004e61feda2c16aa5e21ffa8d7e7f7dbf6ec379a43b48e4b36aeb0",
    )
    _cavp(
        22,
        "334ae0c4693d23935a7e8e043ebbde21e168a7cba3fa507c9be41d7681e049ce",
        "45fb02b2ceb9d7c79d9c2fa93e9c7967c2fa4df5789f9640b24264b1e524fcb1",
        "5c6e8ecf1f7d3023893b7b1ca1e4d178972ee2a230757ddc564ffe37f5c5a321",
        "2adae4a138a239dcd93c243a3803c3e4cf96e37fe14e6a9b717be9599959b11c",
    )
    _cavp(
        23,
        "2c4bde40214fcc3bfc47d4cf434b629acbe9157f8fd0282540331de7942cf09d",
        "a19ef7bff98ada781842fbfc51a47aff39b5935a1c7d9625c8d323d511c92de6",
        "e9c184df75c955e02e02e400ffe45f78f339e1afe6d056fb3245f4700ce606ef",
        "2e277ec30f5ea07d6ce513149b9479b96e07f4b6913b1b5c11305c1444a1bc0b",
    )
    _cavp(
        24,
        "85a268f9d7772f990c36b42b0a331adc92b5941de0b862d5d89a347cbf8faab0",
        "356c5a444c049a52fee0adeb7e5d82ae5aa83030bfff31bbf8ce2096cf161c4b",
        "57d128de8b2a57a094d1a001e572173f96e8866ae352bf29cddaf92fc85b2f92",
        "1e51373bd2c6044c129c436e742a55be2a668a85ae08441b6756445df5493857",
    )


def test_rfc5903_section_8_1() raises:
    """Initiator i with responder g^r, and responder r with initiator g^i."""
    var i = "c88f01f510d9ac3f70a292daa2316de544e9aab8afe84049c62a9c57862d1433"
    var gi = (
        "04"
        + "dad0b65394221cf9b051e1feca5787d098dfe637fc90b9ef945d0c3772581180"
        + "5271a0461cdb8252d61f1c456fa3e59ab1f45b33accf5f58389e0577b8990bb3"
    )
    var r = "c6ef9c5d78ae012a011164acb397ce2088685d8f06bf9be0b283ab46476bee53"
    var gr = (
        "04"
        + "d12dfb5289c8d4f81208b70270398c342296970a0bccb74c736fc7554494bf63"
        + "56fbf3ca366cc23e8157854c13c58d6aac23f046ada30f8353e74f33039872ab"
    )
    var girx = "d6840f6b42f6edafd13116e0e12565202fef8e9ece7dce03812464d04b9442de"
    _check("RFC 5903 8.1 initiator", i, gr, girx)
    _check("RFC 5903 8.1 responder", r, gi, girx)


def test_rfc8291_appendix_a() raises:
    """The Web Push example: both sides derive ecdh_secret."""
    var as_private = (
        "c9f58f89813e9f8e872e71f42aa64e1757c9254dcc62b72ddc010bb4043ea11c"
    )
    var as_public = (
        "04"
        + "fe33f4ab0dea71914db55823f73b54948f41306d920732dbb9a59a5328648220"
        + "0e597a7b7bc260ba1c227998580992e93973002f3012a28ae8f06bbb78e5ec0f"
    )
    var ua_private = (
        "ab5757a70dd4a53e553a6bbf71ffefea2874ec07a6b379e3c48f895a02dc33de"
    )
    var ua_public = (
        "04"
        + "2571b2becdfde360551aaf1ed0f4cd366c11cebe555f89bcb7b186a533391731"
        + "68ece2ebe018597bd30479b86e3c8f8eced577ca59187e9246990db682008b0e"
    )
    var ecdh_secret = (
        "932acbd63208387133837b0cd995911c3441eb66000998614a592727aef6912b"
    )
    _check("RFC 8291 A user agent", ua_private, as_public, ecdh_secret)
    _check("RFC 8291 A application server", as_private, ua_public, ecdh_secret)


def main() raises:
    test_nist_cavp_kas_ecc_cdh_p256()
    print("PASS NIST CAVP KAS ECC CDH P-256 (25 vectors)")
    test_rfc5903_section_8_1()
    print("PASS RFC 5903 section 8.1")
    test_rfc8291_appendix_a()
    print("PASS RFC 8291 appendix A")
