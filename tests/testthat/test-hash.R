# FIPS 180-2 test vectors: whatever computes SHA-256, it must agree.

test_that("hashes match the SHA-256 test vectors", {
  expect_identical(
    hash_text("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  )
  expect_identical(
    hash_bytes(raw()),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  )
  expect_identical(
    hash_text("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  )
})

test_that("text is hashed as its UTF-8 bytes", {
  expect_identical(hash_text("é"), hash_bytes(as.raw(c(0xc3, 0xa9))))
})

test_that("a file hashes the same as its bytes", {
  path <- withr::local_tempfile()
  bytes <- as.raw(sample.int(256, 100000, replace = TRUE) - 1L)
  writeBin(bytes, path)
  expect_identical(hash_file(path), hash_bytes(bytes))
})
