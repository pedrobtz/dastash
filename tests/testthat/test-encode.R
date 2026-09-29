enc_hex <- function(x) paste(format(enc_f64(x)), collapse = "")

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
  expect_error(enc_f64(NaN), class = "dastash_type_error")
  expect_error(enc_f64(NA_real_), class = "dastash_type_error")
  expect_error(enc_f64(c(1, 2)), class = "dastash_type_error")
})

test_that("enc_u64() sorts and round-trips", {
  n <- c(0, 1, 255, 256, 65535, 2^32, 2^40 + 7, 2^53)
  hex <- vapply(n, function(v) paste(format(enc_u64(v)), collapse = ""), character(1))
  expect_identical(order(hex, method = "radix"), seq_along(n))
  for (v in n) expect_identical(dec_u64(enc_u64(v)), v)
})

test_that("enc_u64() refuses what is not a count", {
  for (bad in list(-1, 0.5, 2^53 + 2, NA_real_, c(1, 2))) {
    expect_error(enc_u64(bad), class = "dastash_type_error")
  }
})
