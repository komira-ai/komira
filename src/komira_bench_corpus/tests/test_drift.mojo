# The pinned digests of the corpus. Every query, every suite and every dataset
# has its SHA-256 written here, so a change to the text of a query, to the
# order or membership of a suite, or to a column of a dataset fails this file
# until the digest below is changed in the same commit: an edit is deliberate.
#
# The digests were computed outside this package (sha256sum over the query text
# and over the listing and DDL text described in the doc comments of
# `Query.sha256`, `Suite.sha256` and `Dataset.sha256`).
#
# What each case proves:
# - test_every_query_is_pinned: each query hashes to its pinned digest; a query
#   with no pin, and a pin with no query, are both refused (a query added or
#   removed without a pin fails).
# - test_every_suite_is_pinned: each suite's digest equals the pinned one.
# - test_every_dataset_is_pinned: each dataset's digest equals the pinned one.

from std.testing import assert_equal

from komira_bench_corpus import dataset, dataset_names, suites

def _query_pins() -> List[String]:
    var pins = List[String]()
    pins.append("tpch/q1 81fa839d7e9d660798807b9e441e80b3e487950a88b73ae0b38374984db2b11e")
    pins.append("tpch/q2 a72b5a52c361b444355bc6dbf648da4f138db7a3e7c86a5658924e0b5cd945e4")
    pins.append("tpch/q3 6be452869d8c6d1a57465b9d89b08b34bdbf12d62bd1cf78be551bd8ac2c2e8b")
    pins.append("tpch/q4 c53fa7fb23ccade3c7beeebe33a444b417c2246a765e16bd9185a46ad6bb908d")
    pins.append("tpch/q5 e34357caa64c6a6bddfa7904332496a319d1b3b0a1480dcc15b11b8cd3a92964")
    pins.append("tpch/q6 e261fae94ee7c2f45e1abed4d8193a25eac942c04fad82b198455ffa4a70a158")
    pins.append("tpch/q7 fa7d50d24b7ef34062c07b4747d21d1450f1c4acd16635bc71c7322259c86e16")
    pins.append("tpch/q8 7fd25c6ffc531d5c31c8cd32b2cfbb8ea22860c63c3c5b437db8f94f8ad0f206")
    pins.append("tpch/q9 385d69af388e7a2ae1c1a52921765ea1e062be476258e43056b988b3f6519151")
    pins.append("tpch/q10 a3e7c97ded2fe2c44ea975d7ea70ba602124272f92699726f2265675325bae01")
    pins.append("tpch/q11 ffd338a13cd26cb598bc86a31dea6865f976d6d166e112440d755c11122bf663")
    pins.append("tpch/q12 013271e512e7c66f7b915b388100e2bd26488664bd9b343924d3b707d69e74a2")
    pins.append("tpch/q13 68a7f46d678f589f8ca2b7e7d03987d69d63358bd46a90f72694e36d827f22d2")
    pins.append("tpch/q14 e41a17c2ecb549db7cbb576ea725eaa0d326510d35f340ce17b00812916a4fdd")
    pins.append("tpch/q15 41adc189615757791ccaadb93210650b9440691bc8757f70a8dfc8ef7d63db31")
    pins.append("tpch/q16 a262f006bb42ad3be5bb0a45eeda3d4f79f5287100bf208b7d37dfba6eef9fce")
    pins.append("tpch/q17 2e6f74affde26fcfdf877fb00e12c22915a8fef5c8c241846f4f4f409cae5d2c")
    pins.append("tpch/q18 1939a971a3e2cf5534b147d8ff0dc4f1da1aeaf473708aef36de42e2674064de")
    pins.append("tpch/q19 4afd84bbce83c300720d6cc983ae408962adc5141fa6de858f2e1327fe118410")
    pins.append("tpch/q20 770f915fa4df8f56e7100b799df6e1e2dd94f5286b0ea3ee0fa2e3993e083a44")
    pins.append("tpch/q21 9ca0b0828303a7172ee468910c148846efd4178404c49c5f7263ee3f040575e9")
    pins.append("tpch/q22 a8f798aad4e64b5cfd8431e78d1d907c03c5e42afbb21fca021c434c8330aed3")
    pins.append("clickbench/q0 9427a481e342c1da21a6a49bba4004f6bc72e52016514f3892596ec879e33c39")
    pins.append("clickbench/q1 0bae986eb7e395a5197920aba79b18f762900cabedb2e0c2dac8a2bcca6b3f0f")
    pins.append("clickbench/q2 ba789a7fdd20673d5a1de18603f6241b5abe66edc985128790e53ebd504a323a")
    pins.append("clickbench/q3 7a41406a2ec8d4563146920aaaeb5e23a9f96e51c4a8642b7fa1c225d79b4d71")
    pins.append("clickbench/q4 8ebb700400efe6ab27baaef96502aa9149de0f5c4135d50e8bdc65c423890406")
    pins.append("clickbench/q5 fca8498cf063ef5e2ce1eb9f6dd82e17f7448c7a956c04d7b4e583c767520561")
    pins.append("clickbench/q6 08f216fc8d03ab96c3559be63da4081f58662224c3798008aee3ac1ab1abb919")
    pins.append("clickbench/q7 47d7cff5b9eafc8f779bf904e0a6914c6127917a3f220a742bb339d734031cff")
    pins.append("clickbench/q8 7b87e27cc33f1cd9bf22110694116d08a3ecc45a282f23a2970339d9eea18bbf")
    pins.append("clickbench/q9 291921eb48c5986a9f8bb71fef0c0487a9376010fdf426d61bca3392364417ea")
    pins.append("clickbench/q10 1cb0ac4a6aadf592e9271aeffdbdf66a0ca6ccf03c0f8c07a5521351e6a862aa")
    pins.append("clickbench/q11 fabfa0d177bfe2ccd5fd311e621153f376cdc21703a423f564bc17e703912d45")
    pins.append("clickbench/q12 a7b3920a1404ed0931c242895583578d63a3edf62d5b2ddc121160fb0dd8da1b")
    pins.append("clickbench/q13 b7f0ada2d83d40b85575c4005f152ce7c1b2ba51de52bfc3888f16b63978a1f5")
    pins.append("clickbench/q14 805b298847d0f3639e5b6ec47c4679b6ff81ab1f3c9cf1fc73b3b9aab711f9a6")
    pins.append("clickbench/q15 7fe5294dd40c26422509db2283550893d4fff336e41d419946bc770d60c2edec")
    pins.append("clickbench/q16 4f9802036a97ab8218cb43855378b4f54853e410a7372c5cdf8dcb72f1fae31b")
    pins.append("clickbench/q17 66017e86e30d53ce37147e3395388e241ac760c9bfa98502a981766319843f0b")
    pins.append("clickbench/q18 82cdcb7d71b0b374f67d9a581cbb3648cd122475b5bbf472bf1b6713c555663a")
    pins.append("clickbench/q19 92b71f998052ddb0b3a21ddb5144c1a18520ebb30a02fe54becc125331f9c28a")
    pins.append("clickbench/q20 25375542cc4f63a54ac63e3b0b229700ef84435dd47a3cd0b60efd043f44ab8b")
    pins.append("clickbench/q21 42331ddc60176643f76c498fc5e242d4f3d328391b085658a0ef58d778c23238")
    pins.append("clickbench/q22 71954733ef462faf4fc9863b761ca0dee0f1804cf1f0c092442bd19397552c84")
    pins.append("clickbench/q23 5d549d909d4d5c688b709a04bcc1adebb73ec158f89446f55485ca0f380a8b52")
    pins.append("clickbench/q24 faeff5317136af1eb6c7d08f729b9e9fcc85a2d630571c92616926729e736f8e")
    pins.append("clickbench/q25 ee1d0c5f3c338ad18ec977387f88ac71df24a0baa9f186083a02316d729b1c8a")
    pins.append("clickbench/q26 73cc4a26f72f54f21fae00c1e737d0e8e6eb6dee49b80522683ce8380f05cbde")
    pins.append("clickbench/q27 e5a7051fb4cd0d4de81bf6cda2bd474985d1618e654bab77da10a73d26801925")
    pins.append("clickbench/q28 9743f2d9f8f4dc3618c728b807192062377c7106876355ae794f536eb403ae07")
    pins.append("clickbench/q29 9d3eea6a62feec2cd0bf3d388c00e1f3b93c901620a1d624f105d860edd1ab68")
    pins.append("clickbench/q30 5b15d0f8f265e1f9920ef40ebf8a3c1c4ff540b7e4f23e7d6f5e87714b8ce4a8")
    pins.append("clickbench/q31 559c2ad1ec70e59e237b26bcad1321830fbce15aac05ef296501cc8fcf6e8fa6")
    pins.append("clickbench/q32 af6c7a2d15772efd18d85d74fa32d79130e67a9edaac77ef7423c81fc72f377e")
    pins.append("clickbench/q33 5b16e750905d29d42b58968af73788c42d09f3286659624a08bd8ba4aac5326c")
    pins.append("clickbench/q34 1c50c0bae3010824dd246e798dbfbb59fcb61b3c9998c179c9eb1fc0dcfa1612")
    pins.append("clickbench/q35 f057f57cb184507cbe71b53b02c137400680841cc4f05bc6b776a9dd304dd5b5")
    pins.append("clickbench/q36 88aff5f0fa609797eb8cb59a3e85b52e0b22d9e409fa9a1d6cf0d94d9286f350")
    pins.append("clickbench/q37 f9497e3d80f19715e0a1c1babbe19cfa11b8cc4c0f99f0d17c6a4472ca04977f")
    pins.append("clickbench/q38 8ca603b0325bacd225180269fe66ee013795ac93bdaafb27369cd51124ff667a")
    pins.append("clickbench/q39 f6fc6c9690c025a482fdfeeb1cbb29e67f7f6131fbf24365453fd381726abbf6")
    pins.append("clickbench/q40 fca7abd0fb473cb40b0bf0506d5bde6b1cccf521557851c98ec36ae1add2d0a0")
    pins.append("clickbench/q41 00db93354aa31fc9c68b8d108e23dbb8a0500c9fd8365149ea344d48a104e7db")
    pins.append("clickbench/q42 2e3196a359705db8407e56e2dfd954c78e4078d5eca610a094a7ca7634fd0f33")
    pins.append("h2o/q1 267ccc5453807bd247b67b03af9530b57635c3af343d3496f7da33acdaf7c52b")
    pins.append("h2o/q2 5da271695c26e1acda1e6b4b4a5f8128ba5df3da3a1230b9b36eeb91f7c80b14")
    pins.append("h2o/q3 dc3bc27cfb168921125a01efbfa9517b89f594bafb55b8cc1d8b4ab09c5a6763")
    pins.append("h2o/q4 a8175d00fc567f874f5152bd44b372ed58b57c357d2e9b74fe9b68cd1a434024")
    pins.append("h2o/q5 9596b8c9c8bc626219956eae1b4302268973c758b081a933afb9ffd26fa606f8")
    pins.append("h2o/q6 70cf1ffe4c8897c638800df9170effe4cc8f0c532e655bb3c7b5cab88895e234")
    pins.append("h2o/q7 718a276e3d2752f2d264ae7d0dea33434c6da23690d97c591d659a44fbdbbf43")
    pins.append("h2o/q8 a71214d2989acd29aa868f790d0b9d0f919a915f11d9bad9f66e589dbde0ab3a")
    pins.append("h2o/q9 024d58f1477989a996d0015505244d1c7912e0ac5bfa35b04bfe2b3d3c2b6f1c")
    pins.append("h2o/q10 28ac0e17ec24a13f0f95bc92ab640604f3a18457e756df4ca93b1e313adf9819")
    pins.append("h2o/j1 ed17f3a3da705f8a4e980d96193dcff59c16b067a659c4ec44ff4e326bf335bd")
    pins.append("h2o/j2 620960030f1bfe98dd496445c4c342561c4770582f5c8f34f8d33b605e881b6b")
    pins.append("h2o/j3 28119e2b456b22e9add3c5559e9608cf393692245806d1cbb1d9754d068d473a")
    pins.append("h2o/j4 ac06b516fd783af4a0d86af4d336608f1259aed72064b3e21a9647ff45f35348")
    pins.append("h2o/j5 8deeb1f3ab93c027bd58ebe55e8bf0219c2c2d9edaf9e5a3dc18fa6e26998148")
    return pins^


def _suite_pins() -> List[String]:
    var pins = List[String]()
    pins.append("tpch 3380c79710a9ca00af882cdc1cfe0625e0ffdfde190e8bc5d114c2b1f282ede4")
    pins.append("clickbench 20e25ffd4ef48c2aff759c23480365d10b25217f033169f14cd83d1daee44570")
    pins.append("h2o eebd22d757caf7e49739c0a67502b23322c492454dfe4cc8bfc9cf1c73c96616")
    return pins^


def _dataset_pins() -> List[String]:
    var pins = List[String]()
    pins.append("tpch a795a8e5598fc06fe9b6bf37eafa0e9fd2bd612f7b05dc64fb5443ee548f74ae")
    pins.append("clickbench 0e0a89bfdfa2b769224f3a45f42f119babba960f9f37ad23206fdcbe8221c902")
    pins.append("h2o_groupby 6bbb14483e6c002cf6c1db7b08102f56418d6fd51f25acc44714be69197b65cf")
    pins.append("h2o_join 710f2d77ca52ba9dc32a88c2f455089f809b1a2f1b3cc18550582191844b394d")
    return pins^


def _pinned(pins: List[String], name: String) raises -> String:
    for i in range(len(pins)):
        var parts = pins[i].split(String(" "))
        if String(parts[0]) == name:
            return String(parts[1])
    raise Error("no pin for " + name)


def test_every_query_is_pinned() raises:
    var pins = _query_pins()
    var seen = 0
    var all_suites = suites()
    for s in all_suites:
        for q in s.queries:
            assert_equal(
                q.sha256(), _pinned(pins, q.key()), "drift in " + q.key()
            )
            seen += 1
    assert_equal(seen, len(pins), "a pin has no query, or a query no pin")


def test_every_suite_is_pinned() raises:
    var pins = _suite_pins()
    var all_suites = suites()
    assert_equal(len(all_suites), len(pins))
    for s in all_suites:
        assert_equal(s.sha256(), _pinned(pins, s.id), "drift in suite " + s.id)


def test_every_dataset_is_pinned() raises:
    var pins = _dataset_pins()
    var names = dataset_names()
    assert_equal(len(names), len(pins))
    for i in range(len(names)):
        assert_equal(
            dataset(names[i]).sha256(),
            _pinned(pins, names[i]),
            "drift in dataset " + names[i],
        )


def main() raises:
    test_every_query_is_pinned()
    test_every_suite_is_pinned()
    test_every_dataset_is_pinned()
    print("all drift tests passed")
