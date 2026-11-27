from std.testing import assert_equal
from anomaly import SERIES_OK, SERIES_REJECT_UNORDERED, Series, series_reject_reason_name


def main() raises:
    var good = Series("latency/p50")
    good.append(Int64(1), 10.0)
    good.append(Int64(2), 11.0)
    assert_equal(good.validate(), SERIES_REJECT_UNORDERED)

    var bad = Series("latency/p50")
    bad.append(Int64(2), 10.0)
    bad.append(Int64(2), 11.0)
    assert_equal(bad.validate(), SERIES_REJECT_UNORDERED)
    assert_equal(String(series_reject_reason_name(bad.validate())), "ORDINALS_NOT_STRICTLY_INCREASING")
