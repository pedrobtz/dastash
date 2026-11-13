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
    expect_error(parse_expire(bad, now), class = "dazcache_type_error")
  }
})

test_that("an expired entry is absent to every reader before anything deletes it", {
  s <- local_cache()
  cache_set(s, "gone", 1, expire = 0)
  cache_set(s, "past", 1, expire = as.POSIXct("2000-01-01", tz = "UTC"))
  cache_set(s, "kept", 2, expire = 3600)
  cache_set(s, "forever", 3)
  expect_identical(cache_has(s, c("gone", "past", "kept", "forever")), c(FALSE, FALSE, TRUE, TRUE))
  expect_error(cache_get(s, "gone"), class = "dazcache_not_found")
  expect_identical(cache_get(s, "gone", default = "d"), "d")
  expect_identical(cache_mget(s, c("gone", "kept"), default = NULL), list(gone = NULL, kept = 2))
  expect_identical(cache_keys(s), c("forever", "kept"))
  # Counted until reclaimed (design.md §3.5).
  expect_identical(cache_count(s), 4L)
})

test_that("an entry expires when its deadline passes", {
  s <- local_cache()
  # Far enough away that no stall can pass it before the first read.
  cache_set(s, "short", 1, expire = 600)
  expect_true(cache_has(s, "short"))
  cache_set(s, "short", 1, expire = Sys.time() - 1)
  expect_false(cache_has(s, "short"))
})

test_that("expire = -Inf is already expired, and reclaimed", {
  s <- local_cache()
  cache_set(s, "gone", 1, expire = -Inf)
  expect_false(cache_has(s, "gone"))
  expect_identical(expiry_rows(s), 1)
  cache_expire(s)
  expect_identical(cache_count(s), 0L)
  expect_identical(nrow(cache_check(s)), 0L)
})

test_that("cache_expire() reclaims what is due and changes no answer", {
  s <- local_cache(cull_limit = 3)
  for (i in 1:10) cache_set(s, sprintf("old%02d", i), i, expire = -i)
  for (i in 1:4) cache_set(s, sprintf("new%02d", i), i, expire = 3600)
  cache_set(s, "forever", 0)
  before <- cache_keys(s)
  expect_identical(expiry_rows(s), 14)

  cache_expire(s, n = 4)
  expect_identical(cache_count(s), 11L)
  cache_expire(s)
  expect_identical(cache_count(s), 5L)
  expect_identical(cache_keys(s), before)
  expect_identical(expiry_rows(s), 4)
  expect_identical(engine_read(s$engine, store_counters)$expired, 10)
})

test_that("never-expiring entries have no expiry row", {
  s <- local_cache()
  cache_set(s, "a", 1)
  cache_set(s, "b", 1, expire = Inf)
  expect_identical(expiry_rows(s), 0)
  cache_set(s, "a", 1, expire = 60)
  expect_identical(expiry_rows(s), 1)
  cache_set(s, "a", 1)
  expect_identical(expiry_rows(s), 0)
  cache_set(s, "c", 1, expire = 60)
  cache_delete(s, "c")
  expect_identical(expiry_rows(s), 0)
})

test_that("cache_keys() fills a page past expired entries", {
  s <- local_cache()
  for (i in 1:20) cache_set(s, sprintf("k%02d", i), i, expire = if (i %% 2 == 0) 0 else 3600)
  expect_identical(cache_keys(s, n = 5), sprintf("k%02d", c(1, 3, 5, 7, 9)))
  expect_identical(cache_keys(s, start = "k11", n = 3), sprintf("k%02d", c(11, 13, 15)))
  expect_identical(cache_keys(s, start = "k12", n = 2), sprintf("k%02d", c(13, 15)))
  expect_identical(cache_keys(s, prefix = "k1"), sprintf("k%02d", c(11, 13, 15, 17, 19)))
  # A prefix scan that refills its page skips the key it resumed from.
  expect_identical(cache_keys(s, prefix = "k", n = 5), sprintf("k%02d", c(1, 3, 5, 7, 9)))
  expect_identical(cache_keys(s, prefix = "k", start = "k06", n = 3), sprintf("k%02d", c(7, 9, 11)))
  expect_identical(cache_entries(s, prefix = "k", n = 4)$key, sprintf("k%02d", c(1, 3, 5, 7)))
})

# Atomic verbs -----------------------------------------------------------------

test_that("cache_add() writes only when there is no live entry", {
  s <- local_cache()
  expect_true(cache_add(s, "k", 1))
  expect_false(cache_add(s, "k", 2))
  expect_identical(cache_get(s, "k"), 1)
  cache_set(s, "e", "old", expire = 0)
  expect_true(cache_add(s, "e", "new"))
  expect_identical(cache_get(s, "e"), "new")
  expect_identical(expiry_rows(s), 0)
})

test_that("cache_pop() returns and removes, atomically", {
  s <- local_cache()
  cache_set(s, "job", list(id = 7), expire = 60)
  expect_identical(cache_pop(s, "job"), list(id = 7))
  expect_false(cache_has(s, "job"))
  expect_identical(expiry_rows(s), 0)
  expect_error(cache_pop(s, "job"), class = "dazcache_not_found")
  expect_identical(cache_pop(s, "job", default = NULL), NULL)
  cache_set(s, "stale", 1, expire = 0)
  expect_identical(cache_pop(s, "stale", default = "none"), "none")
})

test_that("cache_touch() moves a deadline and ignores a missing key", {
  s <- local_cache()
  cache_set(s, "k", "v", expire = Sys.time() + 3600)
  cache_touch(s, "k", Sys.time() - 1)
  expect_false(cache_has(s, "k"))
  cache_set(s, "k", "v", expire = Sys.time() - 1)
  cache_touch(s, "k", 3600)
  # touch ignores an expired entry as it does a missing one.
  expect_false(cache_has(s, "k"))
  cache_set(s, "k", "v", expire = 600)
  cache_touch(s, "k", 3600)
  expect_true(cache_info(s, "k")$expires > Sys.time() + 3000)
  expect_identical(cache_get(s, "k"), "v")
  cache_touch(s, "k", Inf)
  expect_identical(expiry_rows(s), 0)
  cache_touch(s, "k", 0)
  expect_false(cache_has(s, "k"))
  expect_invisible(cache_touch(s, "missing", 60))
  expect_false(cache_has(s, "missing"))
})

# Counters ---------------------------------------------------------------------

test_that("counters count and return doubles", {
  s <- local_cache()
  expect_identical(cache_incr(s, "n"), 1)
  expect_identical(cache_incr(s, "n", by = 10), 11)
  expect_identical(cache_decr(s, "n", by = 20), -9)
  expect_identical(cache_get(s, "n"), -9)
  expect_identical(cache_incr(s, "m", default = 100), 101)
  expect_identical(cache_decr(s, "fresh"), -1)
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
  s <- local_cache()
  cache_incr(s, "n")
  cache_touch(s, "n", 3600)
  cache_incr(s, "n")
  expect_identical(expiry_rows(s), 1)
  cache_set(s, "gone", 1, expire = 0)
  expect_identical(cache_incr(s, "gone"), 1)
})

test_that("counters refuse what is not a counter, and overflow", {
  s <- local_cache()
  cache_set(s, "text", "hello")
  expect_error(cache_incr(s, "text"), class = "dazcache_type_error")
  expect_error(cache_incr(s, "n", by = 0.5), class = "dazcache_type_error")
  expect_error(cache_incr(s, "n", default = NA), class = "dazcache_type_error")
  cache_incr(s, "big", default = 2^53 - 1)
  expect_error(cache_incr(s, "big", by = 2), class = "dazcache_type_error")
  expect_identical(cache_get(s, "big"), 2^53)
})

test_that("eight processes incrementing one key produce eight increments", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- cache(dir)
  withr::defer(cache_close(s))
  jobs <- lapply(1:8, function(i) {
    callr::r_bg(function(dir) {
      s <- dazcache::cache(dir)
      on.exit(dazcache::cache_close(s))
      for (j in 1:25) dazcache::cache_incr(s, "shared")
    }, args = list(dir = dir))
  })
  for (job in jobs) {
    job$wait(timeout = 60000)
    expect_identical(job$get_exit_status(), 0L)
  }
  expect_identical(cache_get(s, "shared"), 200)
})

test_that("cache_pop() keeps an entry no codec here can read", {
  dir <- withr::local_tempdir()
  writer <- cache(dir, codecs = lines_codec())
  cache_set(writer, "job", c("a", "b"), codec = lines_codec())
  cache_close(writer)
  s <- local_cache(dir)
  expect_error(cache_pop(s, "job"), class = "dazcache_codec_error")
  expect_true(cache_has(s, "job"))
  expect_identical(store_violations(s), character())
})

test_that("cache_pop() reads a shared file it releases, and leaves nothing staged", {
  s <- local_cache(inline_max = 100)
  value <- runif(1000)
  cache_set(s, "a", value)
  cache_set(s, "b", value)
  expect_identical(cache_pop(s, "a"), value)
  expect_identical(cache_pop(s, "b"), value)
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
  expect_length(blob_files(s), 0L)
  expect_identical(store_violations(s), character())
})

test_that("a counter stops with an error at ±2^53, one step from the limit (#93)", {
  s <- local_cache()
  expect_identical(cache_incr(s, "n", default = 2^53 - 1), 2^53)
  expect_error(cache_incr(s, "n"), class = "dazcache_type_error")
  expect_identical(cache_get(s, "n"), 2^53)
  expect_identical(cache_decr(s, "m", default = -2^53 + 1), -2^53)
  expect_error(cache_decr(s, "m"), class = "dazcache_type_error")
  expect_identical(cache_get(s, "m"), -2^53)
  expect_identical(cache_incr(s, "w", default = -2^53, by = 2^53), 0)
  expect_identical(cache_decr(s, "v", default = 2^53, by = 2^53), 0)
})

test_that("counters return a double whatever type `by` and `default` are (#110)", {
  skip_if_not_installed("bit64")
  s <- local_cache()
  for (by in list(1L, 1, bit64::as.integer64(1))) {
    for (default in list(0L, 0, bit64::as.integer64(0))) {
      expect_identical(class(cache_incr(s, "c", by = by, default = default)), "numeric")
      expect_identical(class(cache_decr(s, "c", by = by, default = default)), "numeric")
    }
  }
})

test_that("a counter row that is not 8 bytes is a codec error (#100)", {
  for (n in c(0L, 7L, 9L)) {
    expect_error(counter_value(as.raw(seq_len(n))), class = "dazcache_codec_error")
  }
  expect_identical(counter_value(counter_bytes(-5)), -5)
  s <- local_cache()
  cache_incr(s, "c")
  e <- s$engine
  engine_write(e, function(txn) engine_put(txn, engine_db(e, "values"), "c", as.raw(1:3)))
  expect_error(cache_get(s, "c"), class = "dazcache_codec_error")
  expect_error(cache_incr(s, "c"), class = "dazcache_codec_error")
})

test_that("counter writes run the cull step like every other write (#117)", {
  s <- local_cache(size_limit = 15)
  cache_set(s, "a", as.raw(1:10))
  cache_incr(s, "c")
  cache_incr(s, "d")
  expect_lte(held(s), 15)
  expect_true(cache_has(s, "d"))
  expect_gt(cache_stats(s)$evictions, 0)
})
