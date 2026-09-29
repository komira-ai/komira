def main() raises:
    var values = List[Int]()
    values.append(7)
    # The bounds check on this index records a source location.
    print(values[0])
