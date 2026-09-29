# Examples are built from text so that R CMD check does not read them as
# undeclared uses of digest or mdbx.
functions_from <- function(src) {
  lapply(src, function(s) eval(parse(text = s), envir = globalenv()))
}

test_that("the package code breaks none of the guards", {
  expect_identical(guard_violations(namespace_functions()), character())
})

test_that("the guards catch what they are for", {
  bad <- functions_from(c(
    hash_key   = "function(x) digest::digest(serialize(x, NULL), algo = 'sha256')",
    hash_raw   = "function(x) digest::digest(x, 'sha256', serialize = TRUE)",
    store_open = "function(p) mdbx::mdbx_env_open(p)",
    store_get  = "function(t, k) mdbx_get(t, k)",
    fail       = "function() stop('no')",
    fail_rlang = "function() rlang::abort('no')"
  ))
  hits <- guard_violations(bad)
  expect_match(hits, "hash_key: serialize\\(\\)", all = FALSE)
  expect_match(hits, "hash_key: digest\\(\\) without serialize = FALSE", all = FALSE)
  expect_match(hits, "hash_raw: digest\\(\\) without serialize = FALSE", all = FALSE)
  expect_match(hits, "store_open: mdbx_env_open\\(\\) outside", all = FALSE)
  expect_match(hits, "store_get: mdbx_get\\(\\) outside", all = FALSE)
  expect_match(hits, "fail: bare stop\\(\\)", all = FALSE)
  expect_match(hits, "fail_rlang: rlang::abort\\(\\) outside", all = FALSE)
})

test_that("the guards allow what the design allows", {
  good <- functions_from(c(
    codec_rds        = "function(x) serialize(x, NULL, version = 3)",
    record_encode    = "function(r) serialize(r, NULL, version = 3)",
    key_hash         = "function(txt) digest::digest(txt, algo = 'sha256', serialize = FALSE)",
    engine_open      = "function(p) mdbx::mdbx_env_open(p, flags = 'ACCEDE')",
    uses_missing_arg = "function(m) m[, 1]"
  ))
  expect_identical(guard_violations(good), character())
})

test_that("calls split over lines and nested functions are still seen", {
  outer <- functions_from(c(outer = "
    function(x) {
      inner <- function(y) {
        digest::digest(
          y,
          algo = 'sha256'
        )
      }
      inner(x)
    }
  "))
  expect_match(guard_violations(outer), "outer: digest")
})
