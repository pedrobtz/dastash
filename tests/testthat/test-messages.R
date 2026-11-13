# The wording of one error per class, with its recovery hint. Classes are
# asserted everywhere else; these snapshots are where a message's text is
# pinned, so a lost or garbled hint shows up in review.

test_that("a missing key says how to get a default instead", {
  s <- local_cache()
  expect_snapshot(cache_get(s, "absent"), error = TRUE, cnd_class = TRUE)
  expect_snapshot(cache_mget(s, c("a", "b")), error = TRUE, cnd_class = TRUE)
})

test_that("an unkeyable value says what keys cover", {
  expect_snapshot(cache_key_chr(function() 1), error = TRUE, cnd_class = TRUE)
})

test_that("type errors name the argument", {
  s <- local_cache()
  expect_snapshot(cache_get(s), error = TRUE, cnd_class = TRUE)
  expect_snapshot(cache_set(s, "k", 1, expire = NA), error = TRUE, cnd_class = TRUE)
})

test_that("an unknown codec says how to pass it", {
  s <- local_cache()
  cache_set(s, "k", c("a", "b"), codec = lines_codec())
  other <- cache(s$dir)
  withr::defer(cache_close(other))
  expect_snapshot(cache_get(other, "k"), error = TRUE, cnd_class = TRUE)
})

test_that("store-level conflicts say to leave the argument out", {
  dir <- withr::local_tempdir()
  cache_close(cache(dir, inline_max = 1000))
  expect_snapshot(cache(dir, inline_max = 10), error = TRUE, cnd_class = TRUE)
})

test_that("read-only and closed handles say so", {
  dir <- withr::local_tempdir()
  cache_close(cache(dir))
  ro <- local_cache(dir, readonly = TRUE)
  expect_snapshot(cache_set(ro, "k", 1), error = TRUE, cnd_class = TRUE)
  s <- cache(withr::local_tempdir())
  cache_close(s)
  expect_snapshot(cache_get(s, "k"), error = TRUE, cnd_class = TRUE)
})

test_that("a busy lock says how to wait longer and how a dead writer recovers", {
  s <- local_cache(timeout = 0)
  local_mocked_bindings(engine_dead_writer_wedges = function() TRUE)
  local_mocked_bindings(
    mdbx_txn_begin = function(...) rlang::abort("busy", class = "mdbx_busy"),
    .package = "mdbx"
  )
  expect_snapshot(cache_set(s, "k", 1), error = TRUE, cnd_class = TRUE)
})

test_that("a full map says to raise map_size", {
  s <- local_cache()
  local_mocked_bindings(
    mdbx_txn_commit = function(...) rlang::abort("MDBX_MAP_FULL", class = "mdbx_map_full"),
    .package = "mdbx"
  )
  expect_snapshot(cache_set(s, "k", 1), error = TRUE, cnd_class = TRUE)
})
