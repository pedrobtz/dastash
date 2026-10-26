# The wording of one error per class, with its recovery hint. Classes are
# asserted everywhere else; these snapshots are where a message's text is
# pinned, so a lost or garbled hint shows up in review.

test_that("a missing key says how to get a default instead", {
  s <- local_stash()
  expect_snapshot(stash_get(s, "absent"), error = TRUE, cnd_class = TRUE)
  expect_snapshot(stash_mget(s, c("a", "b")), error = TRUE, cnd_class = TRUE)
})

test_that("an unkeyable value says what keys cover", {
  expect_snapshot(stash_key_chr(function() 1), error = TRUE, cnd_class = TRUE)
})

test_that("type errors name the argument", {
  s <- local_stash()
  expect_snapshot(stash_get(s), error = TRUE, cnd_class = TRUE)
  expect_snapshot(stash_set(s, "k", 1, expire = NA), error = TRUE, cnd_class = TRUE)
})

test_that("an unknown codec says how to pass it", {
  s <- local_stash()
  stash_set(s, "k", c("a", "b"), codec = lines_codec())
  other <- stash(s$dir)
  withr::defer(stash_close(other))
  expect_snapshot(stash_get(other, "k"), error = TRUE, cnd_class = TRUE)
})

test_that("store-level conflicts say to leave the argument out", {
  dir <- withr::local_tempdir()
  stash_close(stash(dir, inline_max = 1000))
  expect_snapshot(stash(dir, inline_max = 10), error = TRUE, cnd_class = TRUE)
})

test_that("read-only and closed handles say so", {
  dir <- withr::local_tempdir()
  stash_close(stash(dir))
  ro <- local_stash(dir, readonly = TRUE)
  expect_snapshot(stash_set(ro, "k", 1), error = TRUE, cnd_class = TRUE)
  s <- stash(withr::local_tempdir())
  stash_close(s)
  expect_snapshot(stash_get(s, "k"), error = TRUE, cnd_class = TRUE)
})

test_that("a busy lock says how to wait longer and how a dead writer recovers", {
  s <- local_stash(timeout = 0)
  local_mocked_bindings(engine_dead_writer_wedges = function() TRUE)
  local_mocked_bindings(
    mdbx_txn_begin = function(...) rlang::abort("busy", class = "mdbx_busy"),
    .package = "mdbx"
  )
  expect_snapshot(stash_set(s, "k", 1), error = TRUE, cnd_class = TRUE)
})

test_that("a full map says to raise map_size", {
  s <- local_stash()
  local_mocked_bindings(
    mdbx_txn_commit = function(...) rlang::abort("MDBX_MAP_FULL", class = "mdbx_map_full"),
    .package = "mdbx"
  )
  expect_snapshot(stash_set(s, "k", 1), error = TRUE, cnd_class = TRUE)
})
