# Test vectors

Hex dumps of complete messages (header + payload). `#` starts a comment; whitespace is ignored.
`core/tests/test_wire.cpp` decodes each one and checks it re-encodes to the same bytes, so other
implementations (e.g. a Swift port) can test against the same files.
