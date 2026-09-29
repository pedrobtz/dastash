expiry_rows <- function(s) {
  engine_read(s$engine, function(txn) engine_count(txn, engine_db(s$engine, "expiry")))
}

test_that("expire accepts seconds, difftime, POSIXct, NULL and Inf", {
  now <- unclass(Sys.time())
  expect_identical(parse_expire(NULL, now), Inf)
  expect_identical(parse_expire(Inf, now), Inf)
  expect_identical(parse_expire(60, now), now + 60)
  expect_identical(parse_expire(60L, now), now + 60)
  expect_identical(parse_expire(as.difftime(2, units = "hours"), now), now + 7200)
  at <- as.POSIXct("2030-01-01", tz = "UTC")
  expect_identical(parse_expire(at, now), as.double(unclass(at)))
  for (bad in list(NA, NaN, NA_real_, c(1, 2), "1h", as.POSIXlt(Sys.time()), factor(1), list(1))) {
    expect_error(parse_expire(bad, now), class = "dastash_type_error")
  }
})

test_that("an expired entry is absent to every reader before anything deletes it", {
  s <- local_stash()
  stash_set(s, "gone", 1, expire = 0)
  stash_set(s, "past", 1, expire = as.POSIXct("2000-01-01", tz = "UTC"))
  stash_set(s, "kept", 2, expire = 3600)
  stash_set(s, "forever", 3)
  expect_identical(stash_has(s, c("gone", "past", "kept", "forever")), c(FALSE, FALSE, TRUE, TRUE))
  expect_error(stash_get(s, "gone"), class = "dastash_not_found")
  expect_identical(stash_get(s, "gone", default = "d"), "d")
  expect_identical(stash_mget(s, c("gone", "kept"), default = NULL), list(gone = NULL, kept = 2))
  expect_identical(stash_keys(s), c("forever", "kept"))
  # Counted until reclaimed (design.md §3.5).
  expect_identical(stash_count(s), 4L)
})

test_that("an entry expires when its deadline passes", {
  s <- local_stash()
  stash_set(s, "short", 1, expire = 0.3)
  expect_true(stash_has(s, "short"))
  Sys.sleep(0.4)
  expect_false(stash_has(s, "short"))
})

test_that("stash_expire() reclaims what is due and changes no answer", {
  s <- local_stash(cull_limit = 3)
  for (i in 1:10) stash_set(s, sprintf("old%02d", i), i, expire = -i)
  for (i in 1:4) stash_set(s, sprintf("new%02d", i), i, expire = 3600)
  stash_set(s, "forever", 0)
  before <- stash_keys(s)
  expect_identical(expiry_rows(s), 14)

  stash_expire(s, n = 4)
  expect_identical(stash_count(s), 11L)
  stash_expire(s)
  expect_identical(stash_count(s), 5L)
  expect_identical(stash_keys(s), before)
  expect_identical(expiry_rows(s), 4)
  expect_identical(engine_read(s$engine, store_counters)$expired, 10)
})

test_that("never-expiring entries have no expiry row", {
  s <- local_stash()
  stash_set(s, "a", 1)
  stash_set(s, "b", 1, expire = Inf)
  expect_identical(expiry_rows(s), 0)
  stash_set(s, "a", 1, expire = 60)
  expect_identical(expiry_rows(s), 1)
  stash_set(s, "a", 1)
  expect_identical(expiry_rows(s), 0)
  stash_set(s, "c", 1, expire = 60)
  stash_delete(s, "c")
  expect_identical(expiry_rows(s), 0)
})

test_that("stash_keys() fills a page past expired entries", {
  s <- local_stash()
  for (i in 1:20) stash_set(s, sprintf("k%02d", i), i, expire = if (i %% 2 == 0) 0 else 3600)
  expect_identical(stash_keys(s, n = 5), sprintf("k%02d", c(1, 3, 5, 7, 9)))
  expect_identical(stash_keys(s, start = "k11", n = 3), sprintf("k%02d", c(11, 13, 15)))
  expect_identical(stash_keys(s, start = "k12", n = 2), sprintf("k%02d", c(13, 15)))
  expect_identical(stash_keys(s, prefix = "k1"), sprintf("k%02d", c(11, 13, 15, 17, 19)))
})

# Atomic verbs -----------------------------------------------------------------

test_that("stash_add() writes only when there is no live entry", {
  s <- local_stash()
  expect_true(stash_add(s, "k", 1))
  expect_false(stash_add(s, "k", 2))
  expect_identical(stash_get(s, "k"), 1)
  stash_set(s, "e", "old", expire = 0)
  expect_true(stash_add(s, "e", "new"))
  expect_identical(stash_get(s, "e"), "new")
  expect_identical(expiry_rows(s), 0)
})

test_that("stash_pop() returns and removes, atomically", {
  s <- local_stash()
  stash_set(s, "job", list(id = 7), expire = 60)
  expect_identical(stash_pop(s, "job"), list(id = 7))
  expect_false(stash_has(s, "job"))
  expect_identical(expiry_rows(s), 0)
  expect_error(stash_pop(s, "job"), class = "dastash_not_found")
  expect_identical(stash_pop(s, "job", default = NULL), NULL)
  stash_set(s, "stale", 1, expire = 0)
  expect_identical(stash_pop(s, "stale", default = "none"), "none")
})

test_that("stash_touch() moves a deadline and ignores a missing key", {
  s <- local_stash()
  stash_set(s, "k", "v", expire = 0.5)
  stash_touch(s, "k", 3600)
  Sys.sleep(0.6)
  expect_identical(stash_get(s, "k"), "v")
  stash_touch(s, "k", Inf)
  expect_identical(expiry_rows(s), 0)
  stash_touch(s, "k", 0)
  expect_false(stash_has(s, "k"))
  expect_invisible(stash_touch(s, "missing", 60))
  expect_false(stash_has(s, "missing"))
})

# Counters ---------------------------------------------------------------------

test_that("counters count and return doubles", {
  s <- local_stash()
  expect_identical(stash_incr(s, "n"), 1)
  expect_identical(stash_incr(s, "n", by = 10), 11)
  expect_identical(stash_decr(s, "n", by = 20), -9)
  expect_identical(stash_get(s, "n"), -9)
  expect_identical(stash_incr(s, "m", default = 100), 101)
  expect_identical(stash_decr(s, "fresh"), -1)
})

test_that("counters encode signed 64-bit values exactly", {
  for (x in c(0, 1, -1, 255, -256, 2^31, -2^31, 2^32 + 5, -(2^32 + 5), 2^53, -2^53)) {
    expect_identical(counter_value(counter_bytes(x)), x)
    expect_length(counter_bytes(x), 8L)
  }
  expect_identical(counter_bytes(-1), as.raw(rep(0xff, 8)))
  expect_identical(counter_bytes(1), as.raw(c(rep(0, 7), 1)))
})

test_that("a counter keeps its deadline", {
  s <- local_stash()
  stash_incr(s, "n")
  stash_touch(s, "n", 3600)
  stash_incr(s, "n")
  expect_identical(expiry_rows(s), 1)
  stash_set(s, "gone", 1, expire = 0)
  expect_identical(stash_incr(s, "gone"), 1)
})

test_that("counters refuse what is not a counter, and overflow", {
  s <- local_stash()
  stash_set(s, "text", "hello")
  expect_error(stash_incr(s, "text"), class = "dastash_type_error")
  expect_error(stash_incr(s, "n", by = 0.5), class = "dastash_type_error")
  expect_error(stash_incr(s, "n", default = NA), class = "dastash_type_error")
  stash_incr(s, "big", default = 2^53 - 1)
  expect_error(stash_incr(s, "big", by = 2), class = "dastash_type_error")
  expect_identical(stash_get(s, "big"), 2^53)
})

test_that("eight processes incrementing one key produce eight increments", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- stash(dir)
  withr::defer(stash_close(s))
  jobs <- lapply(1:8, function(i) {
    callr::r_bg(function(dir) {
      s <- dastash::stash(dir)
      on.exit(dastash::stash_close(s))
      for (j in 1:25) dastash::stash_incr(s, "shared")
    }, args = list(dir = dir))
  })
  for (job in jobs) {
    job$wait(timeout = 60000)
    expect_identical(job$get_exit_status(), 0L)
  }
  expect_identical(stash_get(s, "shared"), 200)
})
