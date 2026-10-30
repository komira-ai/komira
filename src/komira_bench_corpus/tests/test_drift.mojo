# The pinned digests of the corpus. Every query, every suite and every dataset
# has its SHA-256 written here, so a change to the text of a query, to the
# order or membership of a suite, or to a column of a dataset fails this file
# until the digest below is changed in the same commit: an edit is deliberate.
#
# The digests were computed outside this package (sha256sum over the query text
# and over the listing and DDL text described in the doc comments of
# `Query.sha256`, `Suite.sha256` and `Dataset.sha256`).
#
# The suite pins are keyed `suite/<id>` and the dataset pins `dataset/<name>`: a
# suite and a dataset are both called `tpch`, with different digests, so a bare
# name would collide.
#
# What each case proves:
# - test_every_query_is_pinned: each query hashes to its pinned digest; a query
#   with no pin, and a pin with no query, are both refused (a query added or
#   removed without a pin fails).
# - test_every_suite_is_pinned: each suite's digest equals the pinned one.
# - test_every_dataset_is_pinned: each dataset's digest equals the pinned one.
# - test_suite_title_and_notice_are_pinned: each suite's title and notice equal
#   the text written here, character for character (the suite digest does not
#   cover them), so the "not a TPC result" wording cannot change unnoticed.
# - test_every_query_reads_its_pinned_dataset: each query names the dataset
#   written here (the query digest covers the text only): tpch queries read
#   `tpch`, h2o groupby q1..q10
#   `h2o_groupby` and join j1..j5 `h2o_join`.

from std.testing import assert_equal

from komira_bench_corpus import (
    TPCH_NOTICE,
    dataset,
    dataset_names,
    suites,
)

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
    pins.append("suite/tpch 3380c79710a9ca00af882cdc1cfe0625e0ffdfde190e8bc5d114c2b1f282ede4")
    pins.append("suite/h2o eebd22d757caf7e49739c0a67502b23322c492454dfe4cc8bfc9cf1c73c96616")
    return pins^


def _dataset_pins() -> List[String]:
    var pins = List[String]()
    pins.append("dataset/tpch a795a8e5598fc06fe9b6bf37eafa0e9fd2bd612f7b05dc64fb5443ee548f74ae")
    pins.append("dataset/h2o_groupby 6bbb14483e6c002cf6c1db7b08102f56418d6fd51f25acc44714be69197b65cf")
    pins.append("dataset/h2o_join 710f2d77ca52ba9dc32a88c2f455089f809b1a2f1b3cc18550582191844b394d")
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
        assert_equal(s.sha256(), _pinned(pins, "suite/" + s.id), "drift in suite " + s.id)


def test_every_dataset_is_pinned() raises:
    var pins = _dataset_pins()
    var names = dataset_names()
    assert_equal(len(names), len(pins))
    for i in range(len(names)):
        assert_equal(
            dataset(names[i]).sha256(),
            _pinned(pins, "dataset/" + names[i]),
            "drift in dataset " + names[i],
        )


def test_suite_title_and_notice_are_pinned() raises:
    var all_suites = suites()
    assert_equal(len(all_suites), 2)
    assert_equal(all_suites[0].id, "tpch")
    assert_equal(
        all_suites[0].title, "TPC-H, 22 queries, validation parameters"
    )
    assert_equal(
        all_suites[0].notice,
        (
            "Derived from TPC-H; not a TPC result. TPC-H is a benchmark of the"
            " Transaction Processing Performance Council; a result of this"
            " suite is not comparable to a published TPC-H result."
        ),
    )
    assert_equal(all_suites[0].notice, TPCH_NOTICE)
    assert_equal(all_suites[1].id, "h2o")
    assert_equal(all_suites[1].title, "h2o groupby q1-q10 and join j1-j5")
    assert_equal(all_suites[1].notice, "")


def test_every_query_reads_its_pinned_dataset() raises:
    var all_suites = suites()
    for s in all_suites:
        for q in s.queries:
            var want = String("")
            if s.id == "tpch":
                want = "tpch"
            elif q.id.startswith("j"):
                want = "h2o_join"
            else:
                want = "h2o_groupby"
            assert_equal(q.dataset, want, "dataset of " + q.key())


def main() raises:
    test_every_query_is_pinned()
    test_every_suite_is_pinned()
    test_every_dataset_is_pinned()
    test_suite_title_and_notice_are_pinned()
    test_every_query_reads_its_pinned_dataset()
    print("all drift tests passed")
