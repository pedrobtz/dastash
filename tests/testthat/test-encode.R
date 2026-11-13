test_that("enc_f64() sorts as numbers do", {
  set.seed(1)
  x <- c(
    -Inf, -.Machine$double.xmax, -1e300, -2^53, -1, -0.5, -5e-324, 0, 5e-324,
    2.5e-310, .Machine$double.eps, 0.5, 1, 2^53, 1e300, .Machine$double.xmax, Inf,
    rnorm(300, 0, 1e6), runif(100, -1, 1), exp(rnorm(100, 0, 300))
  )
  x <- x[is.finite(x) | is.infinite(x)]
  hex <- vapply(x, enc_hex, character(1))
  # C-locale string order of the hex is byte order, which is what mdbx sorts by.
  expect_identical(order(hex, method = "radix"), order(x, method = "radix"))
})

test_that("enc_f64() round-trips", {
  for (x in c(-Inf, -1.5, -5e-324, 0, 5e-324, 0.1, 1e300, Inf)) {
    expect_identical(dec_f64(enc_f64(x)), x)
  }
})

test_that("-0 and 0 sort together at zero", {
  expect_lt(enc_hex(-5e-324), enc_hex(-0))
  expect_lte(enc_hex(-0), enc_hex(0))
  expect_lt(enc_hex(0), enc_hex(5e-324))
})

test_that("enc_f64() refuses NA and NaN", {
  expect_error(enc_f64(NaN), class = "dazcache_type_error")
  expect_error(enc_f64(NA_real_), class = "dazcache_type_error")
  expect_error(enc_f64(c(1, 2)), class = "dazcache_type_error")
})

test_that("enc_u64() sorts and round-trips", {
  n <- c(0, 1, 255, 256, 65535, 2^32, 2^40 + 7, 2^53)
  hex <- vapply(n, function(v) paste(format(enc_u64(v)), collapse = ""), character(1))
  expect_identical(order(hex, method = "radix"), seq_along(n))
  for (v in n) expect_identical(dec_u64(enc_u64(v)), v)
})

test_that("enc_u64() refuses what is not a count", {
  for (bad in list(-1, 0.5, 2^53 + 2, NA_real_, c(1, 2))) {
    expect_error(enc_u64(bad), class = "dazcache_type_error")
  }
})

# The bytes on disk under INDEX_ENCODING_VERSION 1 (design.md §7.4), written by
# hand from the definition: big-endian IEEE-754 with every bit of a negative
# inverted and the sign bit of a non-negative set. Order tests alone pass for
# any monotone encoding; these pin the one 0.1.0 writes (#70).
test_that("enc_f64() and enc_u64() write the literal bytes of index encoding 1", {
  hex <- function(x) paste(format(x), collapse = "")
  f64 <- list(
    "0" = "8000000000000000",
    "-0" = "7fffffffffffffff",
    "1" = "bff0000000000000",
    "-1" = "400fffffffffffff",
    "1.5" = "bff8000000000000",
    "Inf" = "fff0000000000000",
    "-Inf" = "000fffffffffffff",
    "1767225600" = "c1da556e40000000",
    "-1767225600" = "3e25aa91bfffffff",
    "4.94065645841247e-324" = "8000000000000001"
  )
  for (x in names(f64)) {
    value <- if (x == "-0") -0 else as.numeric(x)
    expect_identical(hex(enc_f64(value)), f64[[x]], label = x)
    expect_identical(dec_f64(enc_f64(value)), value, label = x)
  }
  expect_identical(hex(enc_u64(0)), "0000000000000000")
  expect_identical(hex(enc_u64(1)), "0000000000000001")
  expect_identical(hex(enc_u64(2^53)), "0020000000000000")
  expect_identical(INDEX_ENCODING_VERSION, 1L)
})

# Counters are int64 two's complement, big-endian (design.md §3.4, D6). ±1
# cannot tell the high word from the low one; these can (#69).
test_that("counters write the literal bytes of a big-endian int64", {
  hex <- function(x) paste(format(x), collapse = "")
  counters <- list(
    "2147483648" = "0000000080000000",
    "-2147483648" = "ffffffff80000000",
    "4294967301" = "0000000100000005",
    "-4294967301" = "fffffffefffffffb",
    "9007199254740991" = "001fffffffffffff",
    "-9007199254740991" = "ffe0000000000001",
    "9007199254740992" = "0020000000000000",
    "-9007199254740992" = "ffe0000000000000"
  )
  for (x in names(counters)) {
    value <- as.numeric(x)
    expect_identical(hex(counter_bytes(value)), counters[[x]], label = x)
    expect_identical(counter_value(counter_bytes(value)), value, label = x)
  }
})

# The index rows of one entry, read raw from the engine and compared with
# literal hex from design.md §7.2: `f64 ‖ stored key` for expiry and stored,
# `tag ‖ 00 ‖ stored key` for tags. store_violations() compares rows with
# index_rows(), the code that writes them, so it cannot see a layout bug (#71).
test_that("an entry's index rows are the literal bytes of design.md §7.2", {
  s <- local_cache()
  e <- s$engine
  now <- 1767225600
  enc <- codec_encode_value(codec_rds(), 1, stage = function() stage_path(s))
  engine_write(e, function(txn) {
    store_put_entry(s, txn, store_key("k"), enc, now, expire = now + 3600, tags = "grp")
  })
  rows <- function(db) {
    engine_read(e, function(txn) {
      vapply(engine_scan(txn, engine_db(e, db)), function(r) paste(format(r), collapse = ""), "")
    })
  }
  expect_identical(rows("expiry"), "c1da5571c40000006b")
  expect_identical(rows("stored"), "c1da556e400000006b")
  expect_identical(rows("tags"), "677270006b")
})
