# komira_column_kernels/tests/test_digest_functions.mojo -- `md5(s)`,
# `sha1(s)` and `sha256(s)` (`digest_functions.mojo`) against published
# known answers, and the four helpers they share.
#
# Provenance of every expected digest:
#   * MD5: the seven-line test suite of RFC 1321, appendix A.5.
#   * SHA-1: RFC 3174 section 7.3, TEST1, TEST2 and TEST4 (TEST4 is ten
#     repetitions of a 64-byte string: 640 bytes, eleven blocks), and the
#     896-bit message of the FIPS 180 examples.
#   * SHA-1 and SHA-256: all 65 NIST CAVP ShortMsg vectors (SHA1ShortMsg.rsp,
#     SHA256ShortMsg.rsp of shabytetestvectors.zip; U.S. Government works in
#     the public domain, 17 U.S.C. section 105), copied verbatim from
#     komira_crypto's own CAVP tests. Messages of 0 to 64 bytes, every length,
#     so each padding boundary is crossed: 55 bytes is the last one-block
#     message and 56 the first two-block one. A ShortMsg vector with Len = 0
#     carries `Msg = 00` by convention and is the empty message here.
#   * SHA-256: FIPS 180-2 appendix B.1 ("abc") and B.2 (the 448-bit message).
#   * One million 'a' (8,000,000 bits, so the bit length needs more than 16
#     bits): SHA-1 from RFC 3174 TEST3 / FIPS 180 (RFC 3174's printed result
#     has a known typo, "CD C4"; the FIPS value is 34aa973c d4c4daa4 ...),
#     SHA-256 from FIPS 180-2 appendix B.3, MD5 from the NESSIE project's MD5
#     test vectors, Set 1, vector #8.
# The CAVP messages are arbitrary bytes, not UTF-8: the kernels digest the
# bytes of the string, whatever they are, and so are handed them unvalidated.

from std.testing import TestSuite, assert_equal

from komira_column_kernels.digest_functions import (
    _hex_digit_lower,
    _hex_lower_bytes_be,
    _hex_lower_bytes_le,
    _padded_length,
    _rotl32,
    _rotr32,
    md5_hex_bytes,
    sha1_hex_bytes,
    sha256_hex_bytes,
)


def _hexnib(c: UInt8) -> UInt8:
    if c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    return c - UInt8(ord("a")) + 10


def _hex_to_bytes(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(bs):
        out.append((_hexnib(bs[i]) << 4) | _hexnib(bs[i + 1]))
        i += 2
    return out^


def _text(bs: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(bs))


def _md5(s: String) -> String:
    return _text(md5_hex_bytes(s))


def _sha1(s: String) -> String:
    return _text(sha1_hex_bytes(s))


def _sha256(s: String) -> String:
    return _text(sha256_hex_bytes(s))


def _repeat(s: String, n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += s
    return out


# -----------------------------------------------------------------------------
# MD5: RFC 1321 A.5
# -----------------------------------------------------------------------------


def test_md5_rfc1321_test_suite() raises:
    assert_equal(_md5(""), "d41d8cd98f00b204e9800998ecf8427e")
    assert_equal(_md5("a"), "0cc175b9c0f1b6a831c399e269772661")
    assert_equal(_md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
    assert_equal(_md5("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
    assert_equal(
        _md5("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b"
    )
    assert_equal(
        _md5("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
        "d174ab98d277d9f5a5611c2c9f419d9f",
    )
    # 80 bytes: the message itself spans two blocks.
    assert_equal(
        _md5(_repeat("1234567890", 8)), "57edf4a22be3c955ac49da2e2107b67a"
    )


# -----------------------------------------------------------------------------
# SHA-1: RFC 3174, FIPS 180, CAVP
# -----------------------------------------------------------------------------


def test_sha1_rfc3174_and_fips_180_examples() raises:
    assert_equal(_sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    assert_equal(
        _sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
    )
    assert_equal(
        _sha1(_repeat("01234567", 80)),
        "dea356a2cddd90c7a7ecedc5ebb563934f460452",
    )
    assert_equal(
        _sha1(
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
            "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        ),
        "a49b2446a02c645bf419f995b67091253a04a259",
    )


def _sha1_cavp_short() -> List[Tuple[String, String]]:
    var v = List[Tuple[String, String]]()
    v.append((String(""), String("da39a3ee5e6b4b0d3255bfef95601890afd80709")))
    v.append((String("36"), String("c1dfd96eea8cc2b62785275bca38ac261256e278")))
    v.append((String("195a"), String("0a1c2d555bbe431ad6288af5a54f93e0449c9232")))
    v.append((String("df4bd2"), String("bf36ed5d74727dfd5d7854ec6b1d49468d8ee8aa")))
    v.append((String("549e959e"), String("b78bae6d14338ffccfd5d5b5674a275f6ef9c717")))
    v.append((String("f7fb1be205"), String("60b7d5bb560a1acf6fa45721bd0abb419a841a89")))
    v.append((String("c0e5abeaea63"), String("a6d338459780c08363090fd8fc7d28dc80e8e01f")))
    v.append((String("63bfc1ed7f78ab"), String("860328d80509500c1783169ebf0ba0c4b94da5e5")))
    v.append((String("7e3d7b3eada98866"), String("24a2c34b976305277ce58c2f42d5092031572520")))
    v.append((String("9e61e55d9ed37b1c20"), String("411ccee1f6e3677df12698411eb09d3ff580af97")))
    v.append((String("9777cf90dd7c7e863506"), String("05c915b5ed4e4c4afffc202961f3174371e90b5c")))
    v.append((String("4eb08c9e683c94bea00dfa"), String("af320b42d7785ca6c8dd220463be23a2d2cb5afc")))
    v.append((String("0938f2e2ebb64f8af8bbfc91"), String("9f4e66b6ceea40dcf4b9166c28f1c88474141da9")))
    v.append((String("74c9996d14e87d3e6cbea7029d"), String("e6c4363c0852951991057f40de27ec0890466f01")))
    v.append((String("51dca5c0f8e5d49596f32d3eb874"), String("046a7b396c01379a684a894558779b07d8c7da20")))
    v.append((String("3a36ea49684820a2adc7fc4175ba78"), String("d58a262ee7b6577c07228e71ae9b3e04c8abcda9")))
    v.append((String("3552694cdf663fd94b224747ac406aaf"), String("a150de927454202d94e656de4c7c0ca691de955d")))
    v.append((String("f216a1cbde2446b1edf41e93481d33e2ed"), String("35a4b39fef560e7ea61246676e1b7e13d587be30")))
    v.append((String("a3cf714bf112647e727e8cfd46499acd35a6"), String("7ce69b1acdce52ea7dbd382531fa1a83df13cae7")))
    v.append((String("148de640f3c11591a6f8c5c48632c5fb79d3b7"), String("b47be2c64124fa9a124a887af9551a74354ca411")))
    v.append((String("63a3cc83fd1ec1b6680e9974a0514e1a9ecebb6a"), String("8bb8c0d815a9c68a1d2910f39d942603d807fbcc")))
    v.append((String("875a90909a8afc92fb7070047e9d081ec92f3d08b8"), String("b486f87fb833ebf0328393128646a6f6e660fcb1")))
    v.append((String("444b25f9c9259dc217772cc4478c44b6feff62353673"), String("76159368f99dece30aadcfb9b7b41dab33688858")))
    v.append((String("487351c8a5f440e4d03386483d5fe7bb669d41adcbfdb7"), String("dbc1cb575ce6aeb9dc4ebf0f843ba8aeb1451e89")))
    v.append((String("46b061ef132b87f6d3b0ee2462f67d910977da20aed13705"), String("d7a98289679005eb930ab75efd8f650f991ee952")))
    v.append((String("3842b6137bb9d27f3ca5bafe5bbb62858344fe4ba5c41589a5"), String("fda26fa9b4874ab701ed0bb64d134f89b9c4cc50")))
    v.append((String("44d91d3d465a4111462ba0c7ec223da6735f4f5200453cf132c3"), String("c2ff7ccde143c8f0601f6974b1903eb8d5741b6e")))
    v.append((String("cce73f2eabcb52f785d5a6df63c0a105f34a91ca237fe534ee399d"), String("643c9dc20a929608f6caa9709d843ca6fa7a76f4")))
    v.append((String("664e6e7946839203037a65a12174b244de8cbc6ec3f578967a84f9ce"), String("509ef787343d5b5a269229b961b96241864a3d74")))
    v.append((String("9597f714b2e45e3399a7f02aec44921bd78be0fefee0c5e9b499488f6e"), String("b61ce538f1a1e6c90432b233d7af5b6524ebfbe3")))
    v.append((String("75c5ad1f3cbd22e8a95fc3b089526788fb4ebceed3e7d4443da6e081a35e"), String("5b7b94076b2fc20d6adb82479e6b28d07c902b75")))
    v.append((String("dd245bffe6a638806667768360a95d0574e1a0bd0d18329fdb915ca484ac0d"), String("6066db99fc358952cf7fb0ec4d89cb0158ed91d7")))
    v.append((String("0321794b739418c24e7c2e565274791c4be749752ad234ed56cb0a6347430c6b"), String("b89962c94d60f6a332fd60f6f07d4f032a586b76")))
    v.append((String("4c3dcf95c2f0b5258c651fcd1d51bd10425d6203067d0748d37d1340d9ddda7db3"), String("17bda899c13d35413d2546212bcd8a93ceb0657b")))
    v.append((String("b8d12582d25b45290a6e1bb95da429befcfdbf5b4dd41cdf3311d6988fa17cec0723"), String("badcdd53fdc144b8bf2cc1e64d10f676eebe66ed")))
    v.append((String("6fda97527a662552be15efaeba32a3aea4ed449abb5c1ed8d9bfff544708a425d69b72"), String("01b4646180f1f6d2e06bbe22c20e50030322673a")))
    v.append((String("09fa2792acbb2417e8ed269041cc03c77006466e6e7ae002cf3f1af551e8ce0bb506d705"), String("10016dc3a2719f9034ffcc689426d28292c42fc9")))
    v.append((String("5efa2987da0baf0a54d8d728792bcfa707a15798dc66743754406914d1cfe3709b1374eaeb"), String("9f42fa2bce6ef021d93c6b2d902273797e426535")))
    v.append((String("2836de99c0f641cd55e89f5af76638947b8227377ef88bfba662e5682babc1ec96c6992bc9a0"), String("cdf48bacbff6f6152515323f9b43a286e0cb8113")))
    v.append((String("42143a2b9e1d0b354df3264d08f7b602f54aad922a3d63006d097f683dc11b90178423bff2f7fe"), String("b88fb75274b9b0fd57c0045988cfcef6c3ce6554")))
    v.append((String("eb60c28ad8aeda807d69ebc87552024ad8aca68204f1bcd29dc5a81dd228b591e2efb7c4df75ef03"), String("c06d3a6a12d9e8db62e8cff40ca23820d61d8aa7")))
    v.append((String("7de4ba85ec54747cdc42b1f23546b7e490e31280f066e52fac117fd3b0792e4de62d5843ee98c72015"), String("6e40f9e83a4be93874bc97cdebb8da6889ae2c7a")))
    v.append((String("e70653637bc5e388ccd8dc44e5eace36f7398f2bac993042b9bc2f4fb3b0ee7e23a96439dc01134b8c7d"), String("3efc940c312ef0dfd4e1143812248db89542f6a5")))
    v.append((String("dd37bc9f0b3a4788f9b54966f252174c8ce487cbe59c53c22b81bf77621a7ce7616dcb5b1e2ee63c2c309b"), String("a0cf03f7badd0c3c3c4ea3717f5a4fb7e67b2e56")))
    v.append((String("5f485c637ae30b1e30497f0fb7ec364e13c906e2813daa34161b7ac4a4fd7a1bddd79601bbd22cef1f57cbc7"), String("a544e06f1a07ceb175a51d6d9c0111b3e15e9859")))
    v.append((String("f6c237fb3cfe95ec8414cc16d203b4874e644cc9a543465cad2dc563488a659e8a2e7c981e2a9f22e5e868ffe1"), String("199d986ed991b99a071f450c6b1121a727e8c735")))
    v.append((String("da7ab3291553c659873c95913768953c6e526d3a26590898c0ade89ff56fbd110f1436af590b17fed49f8c4b2b1e"), String("33bac6104b0ad6128d091b5d5e2999099c9f05de")))
    v.append((String("8cfa5fd56ee239ca47737591cba103e41a18acf8e8d257b0dbe8851134a81ff6b2e97104b39b76e19da256a17ce52d"), String("76d7db6e18c1f4ae225ce8ccc93c8f9a0dfeb969")))
    v.append((String("57e89659d878f360af6de45a9a5e372ef40c384988e82640a3d5e4b76d2ef181780b9a099ac06ef0f8a7f3f764209720"), String("f652f3b1549f16710c7402895911e2b86a9b2aee")))
    v.append((String("b91e64235dbd234eea2ae14a92a173ebe835347239cff8b02074416f55c6b60dc6ced06ae9f8d705505f0d617e4b29aef9"), String("63faebb807f32be708cf00fc35519991dc4e7f68")))
    v.append((String("e42a67362a581e8cf3d847502215755d7ad425ca030c4360b0f7ef513e6980265f61c9fa18dd9ce668f38dbc2a1ef8f83cd6"), String("0e6730bc4a0e9322ea205f4edfff1fffda26af0a")))
    v.append((String("634db92c22010e1cbf1e1623923180406c515272209a8acc42de05cc2e96a1e94c1f9f6b93234b7f4c55de8b1961a3bf352259"), String("b61a3a6f42e8e6604b93196c43c9e84d5359e6fe")))
    v.append((String("cc6ca3a8cb391cd8a5aff1faa7b3ffbdd21a5a3ce66cfaddbfe8b179e4c860be5ec66bd2c6de6a39a25622f9f2fcb3fc05af12b5"), String("32d979ca1b3ed0ed8c890d99ec6dd85e6c16abf4")))
    v.append((String("7c0e6a0d35f8ac854c7245ebc73693731bbbc3e6fab644466de27bb522fcb99307126ae718fe8f00742e6e5cb7a687c88447cbc961"), String("6f18190bd2d02fc93bce64756575cea36d08b1c3")))
    v.append((String("c5581d40b331e24003901bd6bf244aca9e9601b9d81252bb38048642731f1146b8a4c69f88e148b2c8f8c14f15e1d6da57b2daa9991e"), String("68f525feea1d8dbe0117e417ca46708d18d7629a")))
    v.append((String("ec6b4a88713df27c0f2d02e738b69db43abda3921317259c864c1c386e9a5a3f533dc05f3beeb2bec2aac8e06db4c6cb3cddcf697e03d5"), String("a7272e2308622ff7a339460adc61efd0ea8dabdc")))
    v.append((String("0321736beba578e90abc1a90aa56157d871618f6de0d764cc8c91e06c68ecd3b9de3824064503384db67beb7fe012232dacaef93a000fba7"), String("aef843b86916c16f66c84d83a6005d23fd005c9e")))
    v.append((String("d0a249a97b5f1486721a50d4c4ab3f5d674a0e29925d5bf2678ef6d8d521e456bd84aa755328c83fc890837726a8e7877b570dba39579aabdd"), String("be2cd6f380969be59cde2dff5e848a44e7880bd6")))
    v.append((String("c32138531118f08c7dcc292428ad20b45ab27d9517a18445f38b8f0c2795bcdfe3ffe384e65ecbf74d2c9d0da88398575326074904c1709ba072"), String("e5eb4543deee8f6a5287845af8b593a95a9749a1")))
    v.append((String("b0f4cfb939ea785eabb7e7ca7c476cdd9b227f015d905368ba00ae96b9aaf720297491b3921267576b72c8f58d577617e844f9f0759b399c6b064c"), String("534c850448dd486787b62bdec2d4a0b140a1b170")))
    v.append((String("bd02e51b0cf2c2b8d204a026b41a66fbfc2ac37ee9411fc449c8d1194a0792a28ee731407dfc89b6dfc2b10faa27723a184afef8fd83def858a32d3f"), String("6fbfa6e4edce4cc85a845bf0d228dc39acefc2fa")))
    v.append((String("e33146b83e4bb671392218da9a77f8d9f5974147182fb95ba662cb66011989c16d9af104735d6f79841aa4d1df276615b50108df8a29dbc9de31f4260d"), String("018872691d9b04e8220e09187df5bc5fa6257cd9")))
    v.append((String("411c13c75073c1e2d4b1ecf13139ba9656cd35c14201f1c7c6f0eeb58d2dbfe35bfdeccc92c3961cfabb590bc1eb77eac15732fb0275798680e0c7292e50"), String("d98d512a35572f8bd20de62e9510cc21145c5bf4")))
    v.append((String("f2c76ef617fa2bfc8a4d6bcbb15fe88436fdc2165d3074629579079d4d5b86f5081ab177b4c3f530376c9c924cbd421a8daf8830d0940c4fb7589865830699"), String("9f3ea255f6af95c5454e55d7354cabb45352ea0b")))
    v.append((String("45927e32ddf801caf35e18e7b5078b7f5435278212ec6bb99df884f49b327c6486feae46ba187dc1cc9145121e1492e6b06e9007394dc33b7748f86ac3207cfe"), String("a70cfbfe7563dd0e665c7c6715a96a8d756950c0")))
    return v^


def test_sha1_cavp_short_msg_all_65() raises:
    var v = _sha1_cavp_short()
    assert_equal(len(v), 65)
    for i in range(len(v)):
        var msg = _hex_to_bytes(v[i][0])
        assert_equal(len(msg), i, "vector i is i bytes")
        assert_equal(_text(sha1_hex_bytes(_text(msg))), v[i][1], String("Len ") + String(8 * i))


# -----------------------------------------------------------------------------
# SHA-256: FIPS 180-2, CAVP
# -----------------------------------------------------------------------------


def test_sha256_fips_180_2_appendix_b() raises:
    assert_equal(
        _sha256("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )
    assert_equal(
        _sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    )


def _sha256_cavp_short() -> List[Tuple[String, String]]:
    var v = List[Tuple[String, String]]()
    v.append((String(""), String("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")))
    v.append((String("d3"), String("28969cdfa74a12c82f3bad960b0b000aca2ac329deea5c2328ebc6f2ba9802c1")))
    v.append((String("11af"), String("5ca7133fa735326081558ac312c620eeca9970d1e70a4b95533d956f072d1f98")))
    v.append((String("b4190e"), String("dff2e73091f6c05e528896c4c831b9448653dc2ff043528f6769437bc7b975c2")))
    v.append((String("74ba2521"), String("b16aa56be3880d18cd41e68384cf1ec8c17680c45a02b1575dc1518923ae8b0e")))
    v.append((String("c299209682"), String("f0887fe961c9cd3beab957e8222494abb969b1ce4c6557976df8b0f6d20e9166")))
    v.append((String("e1dc724d5621"), String("eca0a060b489636225b4fa64d267dabbe44273067ac679f20820bddc6b6a90ac")))
    v.append((String("06e076f5a442d5"), String("3fd877e27450e6bbd5d74bb82f9870c64c66e109418baa8e6bbcff355e287926")))
    v.append((String("5738c929c4f4ccb6"), String("963bb88f27f512777aab6c8b1a02c70ec0ad651d428f870036e1917120fb48bf")))
    v.append((String("3334c58075d3f4139e"), String("078da3d77ed43bd3037a433fd0341855023793f9afd08b4b08ea1e5597ceef20")))
    v.append((String("74cb9381d89f5aa73368"), String("73d6fad1caaa75b43b21733561fd3958bdc555194a037c2addec19dc2d7a52bd")))
    v.append((String("76ed24a0f40a41221ebfcf"), String("044cef802901932e46dc46b2545e6c99c0fc323a0ed99b081bda4216857f38ac")))
    v.append((String("9baf69cba317f422fe26a9a0"), String("fe56287cd657e4afc50dba7a3a54c2a6324b886becdcd1fae473b769e551a09b")))
    v.append((String("68511cdb2dbbf3530d7fb61cbc"), String("af53430466715e99a602fc9f5945719b04dd24267e6a98471f7a7869bd3b4313")))
    v.append((String("af397a8b8dd73ab702ce8e53aa9f"), String("d189498a3463b18e846b8ab1b41583b0b7efc789dad8a7fb885bbf8fb5b45c5c")))
    v.append((String("294af4802e5e925eb1c6cc9c724f09"), String("dcbaf335360de853b9cddfdafb90fa75567d0d3d58af8db9d764113aef570125")))
    v.append((String("0a27847cdc98bd6f62220b046edd762b"), String("80c25ec1600587e7f28b18b1b18e3cdc89928e39cab3bc25e4d4a4c139bcedc4")))
    v.append((String("1b503fb9a73b16ada3fcf1042623ae7610"), String("d5c30315f72ed05fe519a1bf75ab5fd0ffec5ac1acb0daf66b6b769598594509")))
    v.append((String("59eb45bbbeb054b0b97334d53580ce03f699"), String("32c38c54189f2357e96bd77eb00c2b9c341ebebacc2945f97804f59a93238288")))
    v.append((String("58e5a3259cb0b6d12c83f723379e35fd298b60"), String("9b5b37816de8fcdf3ec10b745428708df8f391c550ea6746b2cafe019c2b6ace")))
    v.append((String("c1ef39cee58e78f6fcdc12e058b7f902acd1a93b"), String("6dd52b0d8b48cc8146cebd0216fbf5f6ef7eeafc0ff2ff9d1422d6345555a142")))
    v.append((String("9cab7d7dcaec98cb3ac6c64dd5d4470d0b103a810c"), String("44d34809fc60d1fcafa7f37b794d1d3a765dd0d23194ebbe340f013f0c39b613")))
    v.append((String("ea157c02ebaf1b22de221b53f2353936d2359d1e1c97"), String("9df5c16a3f580406f07d96149303d8c408869b32053b726cf3defd241e484957")))
    v.append((String("da999bc1f9c7acff32828a73e672d0a492f6ee895c6867"), String("672b54e43f41ee77584bdf8bf854d97b6252c918f7ea2d26bc4097ea53a88f10")))
    v.append((String("47991301156d1d977c0338efbcad41004133aefbca6bcf7e"), String("feeb4b2b59fec8fdb1e55194a493d8c871757b5723675e93d3ac034b380b7fc9")))
    v.append((String("2e7ea84da4bc4d7cfb463e3f2c8647057afff3fbececa1d200"), String("76e3acbc718836f2df8ad2d0d2d76f0cfa5fea0986be918f10bcee730df441b9")))
    v.append((String("47c770eb4549b6eff6381d62e9beb464cd98d341cc1c09981a7a"), String("6733809c73e53666c735b3bd3daf87ebc77c72756150a616a194108d71231272")))
    v.append((String("ac4c26d8b43b8579d8f61c9807026e83e9b586e1159bd43b851937"), String("0e6e3c143c3a5f7f38505ed6adc9b48c18edf6dedf11635f6e8f9ac73c39fe9e")))
    v.append((String("0777fc1e1ca47304c2e265692838109e26aab9e5c4ae4e8600df4b1f"), String("ffb4fc03e054f8ecbc31470fc023bedcd4a406b9dd56c71da1b660dcc4842c65")))
    v.append((String("1a57251c431d4e6c2e06d65246a296915071a531425ecf255989422a66"), String("c644612cd326b38b1c6813b1daded34448805aef317c35f548dfb4a0d74b8106")))
    v.append((String("9b245fdad9baeb890d9c0d0eff816efb4ca138610bc7d78cb1a801ed3273"), String("c0e29eeeb0d3a7707947e623cdc7d1899adc70dd7861205ea5e5813954fb7957")))
    v.append((String("95a765809caf30ada90ad6d61c2b4b30250df0a7ce23b7753c9187f4319ce2"), String("a4139b74b102cf1e2fce229a6cd84c87501f50afa4c80feacf7d8cf5ed94f042")))
    v.append((String("09fc1accc230a205e4a208e64a8f204291f581a12756392da4b8c0cf5ef02b95"), String("4f44c1c7fbebb6f9601829f3897bfd650c56fa07844be76489076356ac1886a4")))
    v.append((String("0546f7b8682b5b95fd32385faf25854cb3f7b40cc8fa229fbd52b16934aab388a7"), String("b31ad3cd02b10db282b3576c059b746fb24ca6f09fef69402dc90ece7421cbb7")))
    v.append((String("b12db4a1025529b3b7b1e45c6dbc7baa8897a0576e66f64bf3f8236113a6276ee77d"), String("1c38bf6bbfd32292d67d1d651fd9d5b623b6ec1e854406223f51d0df46968712")))
    v.append((String("e68cb6d8c1866c0a71e7313f83dc11a5809cf5cfbeed1a587ce9c2c92e022abc1644bb"), String("c2684c0dbb85c232b6da4fb5147dd0624429ec7e657991edd95eda37a587269e")))
    v.append((String("4e3d8ac36d61d9e51480831155b253b37969fe7ef49db3b39926f3a00b69a36774366000"), String("bf9d5e5b5393053f055b380baed7e792ae85ad37c0ada5fd4519542ccc461cf3")))
    v.append((String("03b264be51e4b941864f9b70b4c958f5355aac294b4b87cb037f11f85f07eb57b3f0b89550"), String("d1f8bd684001ac5a4b67bbf79f87de524d2da99ac014dec3e4187728f4557471")))
    v.append((String("d0fefd96787c65ffa7f910d6d0ada63d64d5c4679960e7f06aeb8c70dfef954f8e39efdb629b"), String("49ba38db85c2796f85ffd57dd5ec337007414528ae33935b102d16a6b91ba6c1")))
    v.append((String("b7c79d7e5f1eeccdfedf0e7bf43e730d447e607d8d1489823d09e11201a0b1258039e7bd4875b1"), String("725e6f8d888ebaf908b7692259ab8839c3248edd22ca115bb13e025808654700")))
    v.append((String("64cd363ecce05fdfda2486d011a3db95b5206a19d3054046819dd0d36783955d7e5bf8ba18bf738a"), String("32caef024f84e97c30b4a7b9d04b678b3d8a6eb2259dff5b7f7c011f090845f8")))
    v.append((String("6ac6c63d618eaf00d91c5e2807e83c093912b8e202f78e139703498a79c6067f54497c6127a23910a6"), String("4bb33e7c6916e08a9b3ed6bcef790aaaee0dcf2e7a01afb056182dea2dad7d63")))
    v.append((String("d26826db9baeaa892691b68900b96163208e806a1da077429e454fa011840951a031327e605ab82ecce2"), String("3ac7ac6bed82fdc8cd15b746f0ee7489158192c238f371c1883c9fe90b3e2831")))
    v.append((String("3f7a059b65d6cb0249204aac10b9f1a4ac9e5868adebbe935a9eb5b9019e1c938bfc4e5c5378997a3947f2"), String("bfce809534eefe871273964d32f091fe756c71a7f512ef5f2300bcd57f699e74")))
    v.append((String("60ffcb23d6b88e485b920af81d1083f6291d06ac8ca3a965b85914bc2add40544a027fca936bbde8f359051c"), String("1d26f3e04f89b4eaa9dbed9231bb051eef2e8311ad26fe53d0bf0b821eaf7567")))
    v.append((String("9ecd07b684bb9e0e6692e320cec4510ca79fcdb3a2212c26d90df65db33e692d073cc174840db797504e482eef"), String("0ffeb644a49e787ccc6970fe29705a4f4c2bfcfe7d19741c158333ff6982cc9c")))
    v.append((String("9d64de7161895884e7fa3d6e9eb996e7ebe511b01fe19cd4a6b3322e80aaf52bf6447ed1854e71001f4d54f8931d"), String("d048ee1524014adf9a56e60a388277de194c694cc787fc5a1b554ea9f07abfdf")))
    v.append((String("c4ad3c5e78d917ecb0cbbcd1c481fc2aaf232f7e289779f40e504cc309662ee96fecbd20647ef00e46199fbc482f46"), String("50dbf40066f8d270484ee2ef6632282dfa300a85a8530eceeb0e04275e1c1efd")))
    v.append((String("4eef5107459bddf8f24fc7656fd4896da8711db50400c0164847f692b886ce8d7f4d67395090b3534efd7b0d298da34b"), String("7c5d14ed83dab875ac25ce7feed6ef837d58e79dc601fb3c1fca48d4464e8b83")))
    v.append((String("047d2758e7c2c9623f9bdb93b6597c5e84a0cd34e610014bcb25b49ed05c7e356e98c7a672c3dddcaeb84317ef614d342f"), String("7d53eccd03da37bf58c1962a8f0f708a5c5c447f6a7e9e26137c169d5bdd82e4")))
    v.append((String("3d83df37172c81afd0de115139fbf4390c22e098c5af4c5ab4852406510bc0e6cf741769f44430c5270fdae0cb849d71cbab"), String("99dc772e91ea02d9e421d552d61901016b9fd4ad2df4a8212c1ec5ba13893ab2")))
    v.append((String("33fd9bc17e2b271fa04c6b93c0bdeae98654a7682d31d9b4dab7e6f32cd58f2f148a68fbe7a88c5ab1d88edccddeb30ab21e5e"), String("cefdae1a3d75e792e8698d5e71f177cc761314e9ad5df9602c6e60ae65c4c267")))
    v.append((String("77a879cfa11d7fcac7a8282cc38a43dcf37643cc909837213bd6fd95d956b219a1406cbe73c52cd56c600e55b75bc37ea69641bc"), String("c99d64fa4dadd4bc8a389531c68b4590c6df0b9099c4d583bc00889fb7b98008")))
    v.append((String("45a3e6b86527f20b4537f5af96cfc5ad8777a2dde6cf7511886c5590ece24fc61b226739d207dabfe32ba6efd9ff4cd5db1bd5ead3"), String("4d12a849047c6acd4b2eee6be35fa9051b02d21d50d419543008c1d82c427072")))
    v.append((String("25362a4b9d74bde6128c4fdc672305900947bc3ada9d9d316ebcf1667ad4363189937251f149c72e064a48608d940b7574b17fefc0df"), String("f8e4ccab6c979229f6066cc0cb0cfa81bb21447c16c68773be7e558e9f9d798d")))
    v.append((String("3ebfb06db8c38d5ba037f1363e118550aad94606e26835a01af05078533cc25f2f39573c04b632f62f68c294ab31f2a3e2a1a0d8c2be51"), String("6595a2ef537a69ba8583dfbf7f5bec0ab1f93ce4c8ee1916eff44a93af5749c4")))
    v.append((String("2d52447d1244d2ebc28650e7b05654bad35b3a68eedc7f8515306b496d75f3e73385dd1b002625024b81a02f2fd6dffb6e6d561cb7d0bd7a"), String("cfb88d6faf2de3a69d36195acec2e255e2af2b7d933997f348e09f6ce5758360")))
    v.append((String("4cace422e4a015a75492b3b3bbfbdf3758eaff4fe504b46a26c90dacc119fa9050f603d2b58b398cad6d6d9fa922a154d9e0bc4389968274b0"), String("4d54b2d284a6794581224e08f675541c8feab6eefa3ac1cfe5da4e03e62f72e4")))
    v.append((String("8620b86fbcaace4ff3c2921b8466ddd7bacae07eefef693cf17762dcabb89a84010fc9a0fb76ce1c26593ad637a61253f224d1b14a05addccabe"), String("dba490256c9720c54c612a5bd1ef573cd51dc12b3e7bd8c6db2eabe0aacb846b")))
    v.append((String("d1be3f13febafefc14414d9fb7f693db16dc1ae270c5b647d80da8583587c1ad8cb8cb01824324411ca5ace3ca22e179a4ff4986f3f21190f3d7f3"), String("02804978eba6e1de65afdbc6a6091ed6b1ecee51e8bff40646a251de6678b7ef")))
    v.append((String("f499cc3f6e3cf7c312ffdfba61b1260c37129c1afb391047193367b7b2edeb579253e51d62ba6d911e7b818ccae1553f6146ea780f78e2219f629309"), String("0b66c8b4fefebc8dc7da0bbedc1114f228aa63c37d5c30e91ab500f3eadfcec5")))
    v.append((String("6dd6efd6f6caa63b729aa8186e308bc1bda06307c05a2c0ae5a3684e6e460811748690dc2b58775967cfcc645fd82064b1279fdca771803db9dca0ff53"), String("c464a7bf6d180de4f744bb2fe5dc27a3f681334ffd54a9814650e60260a478e3")))
    v.append((String("6511a2242ddb273178e19a82c57c85cb05a6887ff2014cf1a31cb9ba5df1695aadb25c22b3c5ed51c10d047d256b8e3442842ae4e6c525f8d7a5a944af2a"), String("d6859c0b5a0b66376a24f56b2ab104286ed0078634ba19112ace0d6d60a9c1ae")))
    v.append((String("e2f76e97606a872e317439f1a03fcd92e632e5bd4e7cbc4e97f1afc19a16fde92d77cbe546416b51640cddb92af996534dfd81edb17c4424cf1ac4d75aceeb"), String("18041bd4665083001fba8c5411d2d748e8abbfdcdfd9218cb02b68a78e7d4c23")))
    v.append((String("5a86b737eaea8ee976a0a24da63e7ed7eefad18a101c1211e2b3650c5187c2a8a650547208251f6d4237e661c7bf4c77f335390394c37fa1a9f9be836ac28509"), String("42e61e174fbb3897d6dd6cef3dd2802fe67b331953b06114a65c772859dfc1aa")))
    return v^


def test_sha256_cavp_short_msg_all_65() raises:
    var v = _sha256_cavp_short()
    assert_equal(len(v), 65)
    for i in range(len(v)):
        var msg = _hex_to_bytes(v[i][0])
        assert_equal(len(msg), i, "vector i is i bytes")
        assert_equal(_text(sha256_hex_bytes(_text(msg))), v[i][1], String("Len ") + String(8 * i))


# -----------------------------------------------------------------------------
# One million 'a': the high bytes of the 64-bit bit length
# -----------------------------------------------------------------------------


def _million_a() -> String:
    # Built at run time: a literal of this size would bloat the test binary.
    var bs = List[UInt8](capacity=1_000_000)
    for _ in range(1_000_000):
        bs.append(0x61)
    return _text(bs)


def test_one_million_a() raises:
    var m = _million_a()
    assert_equal(m.byte_length(), 1_000_000)
    assert_equal(_md5(m), "7707d6ae4e027c70eea2a935c2296f21")
    assert_equal(_sha1(m), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    assert_equal(
        _sha256(m),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
    )


# -----------------------------------------------------------------------------
# The shared helpers
# -----------------------------------------------------------------------------


def test_hex_digit_lower_every_nibble() raises:
    var want = "0123456789abcdef".as_bytes()
    for v in range(16):
        assert_equal(_hex_digit_lower(v), want[v], String("nibble ") + String(v))


def test_word_renderers_byte_order() raises:
    var words = List[UInt32]()
    words.append(0x01234567)
    words.append(0x89ABCDEF)
    # SHA order: most significant byte first.
    assert_equal(_text(_hex_lower_bytes_be(words)), "0123456789abcdef")
    # MD5 order: least significant byte first, each byte high nibble first.
    assert_equal(_text(_hex_lower_bytes_le(words)), "67452301efcdab89")


def test_padded_length_boundaries() raises:
    # One 0x80 byte and an 8-byte length must fit after the message: 55 bytes
    # is the most one block holds, 119 the most two do. (A table read at run
    # time: a comparison of two compile-time constants is folded away.)
    var cases = List[Tuple[Int, Int]]()
    cases.append((0, 64))
    cases.append((55, 64))
    cases.append((56, 128))
    cases.append((63, 128))
    cases.append((64, 128))
    cases.append((119, 128))
    cases.append((120, 192))
    for i in range(len(cases)):
        assert_equal(
            _padded_length(cases[i][0]), cases[i][1], String("n=") + String(cases[i][0])
        )


def test_rotations() raises:
    # (word, n, rotl, rotr): bits leaving one end enter the other.
    var cases = List[Tuple[UInt32, Int, UInt32, UInt32]]()
    cases.append((UInt32(0x80000001), 1, UInt32(0x00000003), UInt32(0xC0000000)))
    cases.append((UInt32(0x12345678), 4, UInt32(0x23456781), UInt32(0x81234567)))
    cases.append((UInt32(0x00000001), 31, UInt32(0x80000000), UInt32(0x00000002)))
    cases.append((UInt32(0x80000000), 31, UInt32(0x40000000), UInt32(0x00000001)))
    for i in range(len(cases)):
        ref c = cases[i]
        assert_equal(_rotl32(c[0], c[1]), c[2], String("rotl case ") + String(i))
        assert_equal(_rotr32(c[0], c[1]), c[3], String("rotr case ") + String(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
