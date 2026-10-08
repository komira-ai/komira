from mpdep import answer


def twice() -> Int:
    var values = List[Int]()
    values.append(answer())
    # The bounds check on this index records a source location.
    return values[0] * 2
