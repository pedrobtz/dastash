# A store written by 0.1.0, checked in, read by this version. Round trips
# within one version cannot see a reader that drifts from what an earlier one
# wrote; this can (#72). Never regenerate the fixture to make this pass after
# 0.1.0 is released: a failure means stored caches would no longer read.

local_fixture_store <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  utils::untar(test_path("fixtures", "store-0.1.0.tar.gz"), exdir = dir, tar = "internal")
  dir <- file.path(dir, "store-0.1.0")
  # Blobs are 0444 as 0.1.0 wrote them, whatever the archive kept.
  blobs <- list.files(file.path(dir, "blobs"), recursive = TRUE, full.names = TRUE)
  Sys.chmod(blobs, "0444")
  # Writable again before the directory goes: Windows will not delete them.
  withr::defer(Sys.chmod(blobs, "0644"), envir = env)
  dir
}

test_that("a store written by 0.1.0 reads back every entry, and checks clean", {
  dir <- local_fixture_store()
  s <- cache(dir, readonly = TRUE)
  withr::defer(cache_close(s))
  entries <- fixture_entries(test_path("fixtures", "fixture-file.txt"))
  for (e in entries) {
    got <- cache_get(s, e$key)
    if (identical(e$result, "file")) {
      expect_identical(readLines(got), readLines(e$value))
      expect_true(startsWith(normalizePath(got), normalizePath(dir)))
    } else {
      expect_identical(got, e$value, label = paste(cache_key_chr(e$key) |> substr(1, 40)))
    }
  }
  expect_identical(cache_count(s), length(entries))
  expect_setequal(cache_entries(s, tag = "alpha")$key, "tagged")
  expect_identical(cache_keys(s, prefix = "longlong") |> length(), 1L)
  expect_identical(nrow(cache_check(s, hash = TRUE)), 0L)
  stats <- cache_stats(s)
  expect_identical(stats$bytes_inline + stats$bytes_blob, sum(cache_entries(s)$bytes))
})

test_that("a store written by 0.1.0 takes writes and stays sound", {
  dir <- local_fixture_store()
  s <- cache(dir)
  withr::defer(cache_close(s))
  expect_identical(cache_incr(s, "hits"), 42)
  cache_set(s, "new", runif(500))
  cache_delete(s, "blob")
  cache_expire(s)
  expect_identical(cache_get(s, "expiring"), "until 2100")
  expect_identical(nrow(cache_check(s, hash = TRUE)), 0L)
  expect_identical(store_violations(s), character())
})
