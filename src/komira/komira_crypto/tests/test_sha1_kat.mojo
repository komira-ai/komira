# =============================================================================
# src/komira/komira_crypto/tests/test_sha1_kat.mojo — the known-answer gate for
#   the EVP-backed `Sha1` / `sha1` (`hash.mojo`).
# =============================================================================
#
# WHAT SHA-1 IS FOR HERE: a registry WITNESS (npm's `dist.shasum`), computed
# over whole package tarballs. So this gate holds two things: the digest is
# SHA-1's, bit for bit, and it stays SHA-1's at package scale.
#
# THE ROWS
#   (1) FIPS 180 examples: the empty string, "abc" (one block), the 448-bit
#       two-block message, the 896-bit message, and one million 'a' (the
#       ~1 MB NIST stress vector) — every one on BOTH surfaces (streaming
#       `Sha1` and one-shot `sha1`), which reach AWS-LC through two
#       different entry points (EVP_MD_CTX vs SHA1()).
#   (2) NIST CAVP SHA1ShortMsg — all 65 vectors, Len = 0 .. 512 bits, both
#       surfaces.
#   (3) NIST CAVP SHA1Monte — all 100 checkpoints x 1000 chained digests,
#       both surfaces asserted identical at every step.
#   (4) a MULTI-MB input (5 MiB + 7 bytes, not block-aligned): one-shot,
#       streamed in irregular chunks that straddle block boundaries, and
#       streamed with a fork taken midway — all equal to the known answer.
#   (5) the streaming contract: finalize is idempotent, fork is independent,
#       reset returns to the empty digest, and `Sha1` still reports the SHA-1
#       sizes (20-byte digest, 64-byte block).
#
# PROVENANCE OF EVERY EXPECTED VALUE
#   * (1): FIPS 180 / NIST example values; each also agrees with CPython's
#     `hashlib.sha1` and coreutils `sha1sum` (two implementations independent
#     of AWS-LC and of each other).
#   * (2), (3): copied verbatim from SHA1ShortMsg.rsp and SHA1Monte.rsp in
#     NIST's `shabytetestvectors.zip` (the CAVP "Secure Hashing" byte-oriented
#     vectors — the same archive the SHA-2 CAVP tests were taken from, byte-identical),
#     at
#     https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip
#     A ShortMsg vector with Len = 0 carries `Msg = 00` by CAVP convention and
#     is the EMPTY message here. NIST CAVP vectors are U.S. Government works in
#     the public domain (17 U.S.C. § 105).
#   * (4): no NIST vector is multi-MB short of the 1 GiB "extremely long"
#     message, so the answer is computed by both oracles above and is
#     reproducible in one line:
#       python3 -c "import hashlib;print(hashlib.sha1(bytes(i%251 for i in range(5*2**20+7))).hexdigest())"
#
# Hermetic: no files, no network. Mojo 1.0 (def-only).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_crypto import Sha1, hex_lower, sha1


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------


def _hexnib(c: UInt8) -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    return UInt8(0)


def _hex_to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    var i = 0
    while i + 1 < len(bs):
        out.append((_hexnib(bs[i]) << 4) | _hexnib(bs[i + 1]))
        i += 2
    return out^


def _hex(d: Array[UInt8, 20]) -> String:
    # The package's own lowercase encoder, as `test_sha256_kat` uses
    # `hex_lower_array_32` -- no second hex alphabet in the tree.
    return hex_lower(Span(d))


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _streamed(data: Span[UInt8, _]) -> Array[UInt8, 20]:
    var h = Sha1()
    h.update(data)
    var d = Array[UInt8, 20](fill=0)
    h.finalize_into(d)
    return d^


def _assert_both_surfaces(
    data: Span[UInt8, _], expected: String, label: String
) raises:
    assert_equal(
        _hex(_streamed(data)), expected, String("streaming Sha1: ") + label
    )
    assert_equal(_hex(sha1(data)), expected, String("one-shot sha1: ") + label)


# -----------------------------------------------------------------------------
# (1) FIPS 180 examples.
# -----------------------------------------------------------------------------


def test_fips_180_examples() raises:
    var empty = List[UInt8]()
    _assert_both_surfaces(
        empty,
        String("da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        String("the empty message"),
    )
    var abc = _bytes_of(String("abc"))
    _assert_both_surfaces(
        abc,
        String("a9993e364706816aba3e25717850c26c9cd0d89d"),
        String("'abc' — one block"),
    )
    var m448 = _bytes_of(
        String("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    )
    _assert_both_surfaces(
        m448,
        String("84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
        String("the 448-bit message — padding spills into a second block"),
    )
    var m896 = _bytes_of(
        String(
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
            "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        )
    )
    _assert_both_surfaces(
        m896,
        String("a49b2446a02c645bf419f995b67091253a04a259"),
        String("the 896-bit message"),
    )
    var million_a = List[UInt8](capacity=1_000_000)
    for _i in range(1_000_000):
        million_a.append(UInt8(0x61))
    _assert_both_surfaces(
        million_a,
        String("34aa973cd4c4daa4f61eeb2bdbad27316534016f"),
        String("one million 'a' — the NIST stress vector"),
    )
    print("  test_fips_180_examples: PASS")


# -----------------------------------------------------------------------------
# (2) NIST CAVP SHA1ShortMsg — all 65 vectors, verbatim.
# -----------------------------------------------------------------------------


def _cavp_short_vectors() -> List[Tuple[String, String]]:
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


def test_cavp_short_msg_all() raises:
    var v = _cavp_short_vectors()
    assert_equal(len(v), 65, "SHA1ShortMsg.rsp holds 65 vectors (Len 0..512)")
    for i in range(len(v)):
        ref entry = v[i]
        var data = _hex_to_bytes(entry[0])
        assert_equal(len(data), i, "vector i is i bytes long (Len = 8i bits)")
        _assert_both_surfaces(
            data, entry[1], String("CAVP ShortMsg vector ") + String(i)
        )
    print("  test_cavp_short_msg_all: PASS (65 vectors x 2 surfaces)")


# -----------------------------------------------------------------------------
# (3) NIST CAVP SHA1Monte — CAVS-SHS §6.4, all 100 checkpoints.
#
#   MD[0] = MD[1] = MD[2] = Seed
#   for j in 0..99:
#       for i in 3..1002:
#           MD[i] = SHA-1(MD[i-3] || MD[i-2] || MD[i-1])
#       checkpoint[j] = MD[1002]
#       MD[0] = MD[1] = MD[2] = MD[1002]
# -----------------------------------------------------------------------------


def _monte_seed() -> String:
    return String("dd4df644eaf3d85bace2b21accaa22b28821f5cd")


def _monte_checkpoints() -> List[String]:
    var v = List[String]()
    v.append(String("11f5c38b4479d4ad55cb69fadf62de0b036d5163"))
    v.append(String("5c26de848c21586bec36995809cb02d3677423d9"))
    v.append(String("453b5fcf263d01c891d7897d4013990f7c1fb0ab"))
    v.append(String("36d0273ae363f992bbc313aa4ff602e95c207be3"))
    v.append(String("d1c65e9ac55727fbf30eaf5f00cc22b9bab81a2c"))
    v.append(String("2c477cd77e5749da7fc4e5ca7eed77166e8ceae6"))
    v.append(String("60b11211137f46863501a32a435976eabd4532f3"))
    v.append(String("0894f4f012a1e5344044e0ecfa6f078382064602"))
    v.append(String("06b6222855cae9bed77e9e3050d164a98286ea5f"))
    v.append(String("e2872694d3d23a68a24419c35bd9ac9006248a8f"))
    v.append(String("ea43595eb1cff3a7e045c5868d0775b4409b14a3"))
    v.append(String("05a9e94fdc792a61aa60bcd37592acee1f983280"))
    v.append(String("7d11aa9413cd89a387a5c0f9aa5ce541be2aa6e8"))
    v.append(String("37297d053aaa4a845cc9ce0c0165644ab8d0e00b"))
    v.append(String("d9dcde396d69748c1fe357f8b662a27ce89082c8"))
    v.append(String("737a484499b6858b14e656c328979e8aa56b0a43"))
    v.append(String("4e9c8b3bce910432ac2ad17d51e6b9ec4f92c1ad"))
    v.append(String("62325b9a7cebcc6da3bfe781d84eb53a6eb7b019"))
    v.append(String("4710670e071609d470f7d628d8ea978dfb9234ac"))
    v.append(String("23baee80eee052f3263ac26dd12ea6504a5bd234"))
    v.append(String("9451efb9c9586a403747acfa3ec74d359bb9d7ff"))
    v.append(String("37e9d7c81b79f090c8e05848050936c64a1bd662"))
    v.append(String("a6489ff37141f7a86dd978f685fdd4789d1993dc"))
    v.append(String("39650d32501dfcee212d0de10af9db47e4e5af65"))
    v.append(String("cd4ea3474e046b281da5a4bf69fd873ef8d568d6"))
    v.append(String("0d7b518c07c6da877eee35301a99c7563f1840df"))
    v.append(String("68a70ae466532f7f61af138889c0d3f9670f3590"))
    v.append(String("c0222aae5fd2b9eff143ac93c4493abe5c8806af"))
    v.append(String("d2efc5aa0b29db15f3e5de82aaa0a8ce888ffb2f"))
    v.append(String("eec4f55d02c627dcee36b5b5606603bdc9a94a26"))
    v.append(String("0e706fb1a1fa26aab74efcef57ab6a49c07ca7bd"))
    v.append(String("2ea392ca8043686424f7e9500edfb9e9297943f7"))
    v.append(String("74737ef257b32a4cb9428c866b65bee62ccbe653"))
    v.append(String("df3e86e49a0429fa81f553b04b9fc003510e9a51"))
    v.append(String("79c3049944fbf8b80dadadc7f5174e5cfdf996de"))
    v.append(String("f25e2eca4cfb6da8e8b7b62f581672fab80754fa"))
    v.append(String("76509239d9fd6c6f050c0d9b3777b5645e4d4c70"))
    v.append(String("cf4bb3e1f330c862e239d9b010bd842f302bd227"))
    v.append(String("4eeac7ab2ac9e4c81ed1a93a300b2af75beddb08"))
    v.append(String("46443ba72a64fff4b5252fbac9ef93c2949f8585"))
    v.append(String("5e9c42482343a54aadb11ab00c2e00cbe25ec91a"))
    v.append(String("93acee1977128f2a4218678b32e2844f23eb526b"))
    v.append(String("226065d299b2d6c582d386897b93f2adf14de00b"))
    v.append(String("672fed0d90c21d4ec0111a7284bcf1bbd72af9bd"))
    v.append(String("90d642f12f28cb3dad7daad84cf0f94ded1137ae"))
    v.append(String("4a2815b58ffc858e5e7e9e6106765458d2af4ec3"))
    v.append(String("29fa3679032421b78b7a08c54766c1592f6739c1"))
    v.append(String("19f4e30393eb66c6e200744fa8999d224e6df173"))
    v.append(String("30650026be77212088ab50438e04b4b8e3761977"))
    v.append(String("993d0e135bcd598fa673c6f19251bcbde18b7b34"))
    v.append(String("c9eaf20b473219a70efe85940620426c6ff6f4a4"))
    v.append(String("6325d0b83c308bd42854ce69446e85ba36348d7d"))
    v.append(String("2fb354f8a68030efb747f78812060a9c05e92164"))
    v.append(String("a7e33bd16f770c17e8818ad5a5fc4fee673eae56"))
    v.append(String("ff23e7105bc9f4dad0fb9c6519d1eae16439a5d6"))
    v.append(String("a31aca821e163213cd2ae84cf56c1134daa4a621"))
    v.append(String("94ab9cfd4cf9bf2e4409dbcdc9ef2c8b611cc69d"))
    v.append(String("c0194064ce48dde771b7871efa86a4a6e87eec76"))
    v.append(String("f1a9065e3e7f98753c6f833f5ffe74133f6b887f"))
    v.append(String("b8b3cd6ca1d5b5610e43212f8df75211aaddcf96"))
    v.append(String("33c3a8d739cc2f83be597aa11c43e2ad6f0d2436"))
    v.append(String("4f5c67e5110f3663b7aa88759dbba6fa82f2d705"))
    v.append(String("b1ebc87c7b2b8fe73e7a882d3f4f0492946e0d7c"))
    v.append(String("01566616fe4a8c7cf22f21031ac6ea7fb7ce15db"))
    v.append(String("5650f3517a393792781d23b4c9d360bf8bd31d65"))
    v.append(String("a4fdbd24cb4a328b898b804b103caa98baedd3fa"))
    v.append(String("0cf01eecec4b85aa39f40aa9b4dce208d68eb17b"))
    v.append(String("ae9ac147bab7c10609abe6e931a5ab087a41dc5a"))
    v.append(String("c0328145ce63fb0aceeb414e791d2be92009b1ec"))
    v.append(String("60343e5fb7eee00d31ea507b820ddbb7ef405dc7"))
    v.append(String("e0b97cd9149ff9955b6a35b3a79ecb3bdbd2a5a5"))
    v.append(String("4e4fdcd382ae0f3f4fbda5fd934eee0d6ad37df5"))
    v.append(String("9d97dd237d193482cf3ab862a38843762e69077f"))
    v.append(String("2bc927d17ff2f8a844f6f36a944a64d73d431192"))
    v.append(String("b91200306b769aab18e5e411b5bd5e7bce1cc80e"))
    v.append(String("c47493a666085e1b7a75618761a80c402f46546d"))
    v.append(String("31355869b80ff84fac239db694ada07d3be26b15"))
    v.append(String("1a2022f6330bf96f025cb7d8f0201a7d70b3b58e"))
    v.append(String("0f60d7c5ad49efce939c3a27da9973f7f1747848"))
    v.append(String("ceada087801616fc6c08cfa469658f3dc5239ca7"))
    v.append(String("4ad0cf9181122b06df714397bd5366aa90bfc9fa"))
    v.append(String("ac6404e6b9d5c0fa17fa77fd39850f22b76ecd83"))
    v.append(String("f0658218adffb9ee9328577854b6387393957a3a"))
    v.append(String("6fe9992747897389957b9a91467a4ec983829ab6"))
    v.append(String("74320b3ddde6dbfbdad3ad29a7695f5a275b2105"))
    v.append(String("2009ea5d6452f51d12477740e374e0e313134779"))
    v.append(String("7dbf33d7125709f101fea4ec03436ab95a900c28"))
    v.append(String("0c05b78e324cb265bd6adc7452249eaa85bccb3f"))
    v.append(String("10c1b9b2de8a9050fb6f4b10a99f7e1e47159f25"))
    v.append(String("20072c1f691142d9b83a090dd01f446b4e325a1c"))
    v.append(String("ffcb6a1525f20803cfc79deb40addfd3e7b2f05c"))
    v.append(String("bdcbb4ed636e244bb0fe6af4bc53998936df4ebc"))
    v.append(String("f58ccbc65a2ffa5b35274dd0ceb4ea70eb73c26a"))
    v.append(String("fbe95ac75e4b9cccd1a5debf757fa1a502d07944"))
    v.append(String("a8babac55950dba4993601d35adff874a2b9bb2a"))
    v.append(String("594db79de71c7651e9eef2f08bb7be3d26b6ee99"))
    v.append(String("63377d45d0e2d0c987bebe8086c76a5e8b63a14b"))
    v.append(String("cd1e7a192130866aa87fd1c8b43e9b7a0eab7615"))
    v.append(String("b3c69ad5dbdd34b7b45b2a89dad72f4cf1d8fd73"))
    v.append(String("01b7be5b70ef64843a03fdbb3b247a6278d2cbe1"))
    return v^


def test_cavp_monte_all() raises:
    var seed = _hex_to_bytes(_monte_seed())
    assert_equal(len(seed), 20, "the Monte seed is one SHA-1 digest")
    var checkpoints = _monte_checkpoints()
    assert_equal(len(checkpoints), 100, "SHA1Monte.rsp holds 100 checkpoints")

    var md_m3 = seed.copy()
    var md_m2 = seed.copy()
    var md_m1 = seed.copy()
    for j in range(100):
        for _i in range(1000):
            var m = List[UInt8](capacity=60)
            for k in range(20):
                m.append(md_m3[k])
            for k in range(20):
                m.append(md_m2[k])
            for k in range(20):
                m.append(md_m1[k])
            var streamed = _streamed(m)
            var one_shot = sha1(m)
            for k in range(20):
                if streamed[k] != one_shot[k]:
                    assert_equal(
                        _hex(streamed),
                        _hex(one_shot),
                        String("Monte: the two surfaces disagree in chain ")
                        + String(j),
                    )
            md_m3 = md_m2^
            md_m2 = md_m1^
            md_m1 = List[UInt8](capacity=20)
            for k in range(20):
                md_m1.append(streamed[k])
        var got = Array[UInt8, 20](fill=0)
        for k in range(20):
            got[k] = md_m1[k]
        assert_equal(
            _hex(got),
            checkpoints[j],
            String("Monte checkpoint ") + String(j),
        )
        md_m3 = md_m1.copy()
        md_m2 = md_m1.copy()
    print("  test_cavp_monte_all: PASS (100 x 1000 chained digests x 2 surfaces)")


# -----------------------------------------------------------------------------
# (4) a MULTI-MB input — the scale npm tarballs are hashed at.
# -----------------------------------------------------------------------------

comptime _MULTI_MB_LEN: Int = 5 * 1024 * 1024 + 7
comptime _MULTI_MB_SHA1: String = "7954b1b045f7e4c17381e315c0e2a2b96f7216d5"


def _multi_mb_input() -> List[UInt8]:
    """byte i = i mod 251 — a prime period, so no two 64-byte blocks repeat
    in phase and a chunk-boundary bug cannot hide behind identical blocks."""
    var out = List[UInt8](capacity=_MULTI_MB_LEN)
    for i in range(_MULTI_MB_LEN):
        out.append(UInt8(i % 251))
    return out^


def test_multi_mb_input_one_shot_and_streamed() raises:
    var buf = _multi_mb_input()
    assert_equal(len(buf), _MULTI_MB_LEN, "the input is 5 MiB + 7 bytes")

    assert_equal(
        _hex(sha1(buf)), String(_MULTI_MB_SHA1), "one-shot sha1 over 5 MiB + 7"
    )

    # Streamed in chunk sizes that land on, just before and just after the
    # 64-byte block boundary, and far across it.
    var sizes = List[Int]()
    sizes.append(1)
    sizes.append(63)
    sizes.append(64)
    sizes.append(65)
    sizes.append(4095)
    sizes.append(65537)
    sizes.append(1000003)
    var h = Sha1()
    var at = 0
    var n = 0
    while at < len(buf):
        var step = sizes[n % len(sizes)]
        var end = at + step
        if end > len(buf):
            end = len(buf)
        h.update(Span(buf)[at:end])
        at = end
        n += 1
    var streamed = Array[UInt8, 20](fill=0)
    h.finalize_into(streamed)
    assert_equal(
        _hex(streamed),
        String(_MULTI_MB_SHA1),
        "streamed in irregular chunks straddling block boundaries",
    )

    # A fork taken midway finishes to the same answer as the original.
    var half = len(buf) // 2 + 13
    var h1 = Sha1()
    h1.update(Span(buf)[0:half])
    var h2 = h1.fork()
    h1.update(Span(buf)[half : len(buf)])
    h2.update(Span(buf)[half : len(buf)])
    var d1 = Array[UInt8, 20](fill=0)
    var d2 = Array[UInt8, 20](fill=0)
    h1.finalize_into(d1)
    h2.finalize_into(d2)
    assert_equal(_hex(d1), String(_MULTI_MB_SHA1), "the original after a fork")
    assert_equal(_hex(d2), String(_MULTI_MB_SHA1), "the fork, finished apart")
    print("  test_multi_mb_input_one_shot_and_streamed: PASS")


# -----------------------------------------------------------------------------
# (5) the streaming contract.
# -----------------------------------------------------------------------------


def test_streaming_contract() raises:
    assert_equal(Sha1.OUTPUT_SIZE, 20, "a SHA-1 digest is 20 bytes")
    assert_equal(Sha1.BLOCK_SIZE, 64, "a SHA-1 block is 64 bytes")

    var ab = _bytes_of(String("ab"))
    var c = _bytes_of(String("c"))
    var more = _bytes_of(String("more"))
    var h = Sha1()
    h.update(ab)
    var once = Array[UInt8, 20](fill=0)
    var twice = Array[UInt8, 20](fill=0)
    h.finalize_into(once)
    h.finalize_into(twice)
    assert_equal(_hex(once), _hex(twice), "finalize is idempotent")

    # Keep absorbing after a finalize: 'ab' + 'c' is 'abc'.
    h.update(c)
    var abc = Array[UInt8, 20](fill=0)
    h.finalize_into(abc)
    assert_equal(
        _hex(abc),
        String("a9993e364706816aba3e25717850c26c9cd0d89d"),
        "a finalize does not consume the running state",
    )

    var f = h.fork()
    h.update(more)
    var forked = Array[UInt8, 20](fill=0)
    f.finalize_into(forked)
    assert_equal(
        _hex(forked),
        String("a9993e364706816aba3e25717850c26c9cd0d89d"),
        "a fork does not see what the original absorbed after it",
    )
    var extended = Array[UInt8, 20](fill=0)
    h.finalize_into(extended)
    assert_false(_hex(extended) == _hex(forked), "and the original moved on")

    h.reset()
    var empty = Array[UInt8, 20](fill=0)
    h.finalize_into(empty)
    assert_equal(
        _hex(empty),
        String("da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        "reset returns to the empty-message state",
    )
    print("  test_streaming_contract: PASS")


def main() raises:
    test_fips_180_examples()
    test_cavp_short_msg_all()
    test_cavp_monte_all()
    test_multi_mb_input_one_shot_and_streamed()
    test_streaming_contract()
    print("test_sha1_kat: ALL PASS")
