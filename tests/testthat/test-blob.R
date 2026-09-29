blob_files <- function(s) {
  list.files(file.path(s$dir, "blobs"), recursive = TRUE)
}

test_that("a value of inline_max bytes or more becomes a read-only file", {
  s <- local_stash(inline_max = 1000)
  small <- 1:10
  big <- runif(1000)
  stash_set(s, "small", small)
  stash_set(s, "big", big)
  expect_identical(stash_get(s, "big"), big)
  expect_identical(stash_get(s, "small"), small)
  expect_error(stash_path(s, "small"), class = "dastash_type_error")
  path <- stash_path(s, "big")
  expect_match(basename(path), "^[0-9a-f]{64}\\.rds$")
  expect_identical(basename(dirname(path)), substr(basename(path), 1, 2))
  expect_identical(readRDS(path), big)
  if (.Platform$OS.type == "unix") expect_identical(format(file.info(path)$mode), "444")
  expect_identical(tools::sha256sum(path)[[1]], sub("\\.rds$", "", basename(path)))
  expect_identical(store_violations(s), character())
})

test_that("identical bytes are one file, kept while any key refers to it", {
  s <- local_stash(inline_max = 100)
  x <- runif(100)
  stash_set(s, "a", x)
  stash_set(s, "b", x)
  expect_identical(stash_path(s, "a"), stash_path(s, "b"))
  expect_length(blob_files(s), 1L)
  stash_delete(s, "a")
  expect_true(file.exists(stash_path(s, "b")))
  expect_identical(stash_get(s, "b"), x)
  stash_delete(s, "b")
  expect_length(blob_files(s), 0L)
  expect_identical(store_violations(s), character())
})

test_that("replacing an entry releases its old file, and the same bytes stay", {
  s <- local_stash(inline_max = 100)
  x <- runif(100)
  y <- runif(100)
  stash_set(s, "k", x)
  old <- stash_path(s, "k")
  stash_set(s, "k", x)
  expect_true(file.exists(old))
  stash_set(s, "k", y)
  expect_false(file.exists(old))
  stash_set(s, "k", "now inline")
  expect_length(blob_files(s), 0L)
  stash_set(s, "k", y)
  expect_length(blob_files(s), 1L)
  expect_identical(store_violations(s), character())
})

test_that("codec_file() stores a copy, with its extension, even when small", {
  s <- local_stash()
  src <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("a,b", "1,2"), src)
  stash_set(s, "table", src, codec = codec_file())
  path <- stash_get(s, "table")
  expect_match(path, "\\.csv$")
  expect_identical(path, stash_path(s, "table"))
  expect_identical(readLines(path), c("a,b", "1,2"))
  unlink(src)
  expect_true(file.exists(path))
})

test_that("pop returns a stored file's value before the file goes", {
  s <- local_stash(inline_max = 100)
  x <- runif(1000)
  stash_set(s, "k", x)
  path <- stash_path(s, "k")
  expect_identical(stash_pop(s, "k"), x)
  expect_false(file.exists(path))
  expect_identical(store_violations(s), character())
})

test_that("staging leaves nothing behind", {
  s <- local_stash(inline_max = 100)
  x <- runif(100)
  stash_set(s, "a", x)
  stash_set(s, "b", x)
  stash_mset(s, list(c = x, d = runif(100)))
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
  expect_error(stash_set(s, "bad", c("a", NA), codec = codec_raw()), class = "dastash_type_error")
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
})

test_that("volume counts the database and every file once", {
  s <- local_stash(inline_max = 100)
  x <- runif(1000)
  base <- stash_volume(s)
  stash_set(s, "a", x)
  stash_set(s, "b", x)
  one <- file.size(stash_path(s, "a"))
  expect_equal(stash_volume(s) - as.double(engine_info(s$engine)$file_size), one)
  expect_gte(stash_volume(s), base)
})

test_that("a file that is missing or the wrong size is dastash_blob_corrupt", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "k", runif(100))
  path <- stash_path(s, "k")
  Sys.chmod(path, "0644")
  writeBin(as.raw(1:10), path)
  cnd <- expect_error(stash_get(s, "k"), class = "dastash_blob_corrupt")
  expect_identical(cnd$path, path)
  unlink(path)
  expect_error(stash_get(s, "k"), class = "dastash_blob_corrupt")
})

test_that("a file removed with its entry by another writer reads as a miss", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "k", runif(100))
  key <- store_key("k")
  # The read that found the entry, then another writer deletes it.
  hit <- engine_read(s$engine, function(txn) store_read_entry(s, txn, key))
  stash_delete(s, "k")
  expect_null(store_decode_entry(s, hit, key))
})

test_that("a file that vanishes as the decoder opens it reads as a miss", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "k", runif(100))
  key <- store_key("k")
  hit <- engine_read(s$engine, function(txn) store_read_entry(s, txn, key))
  vanishing <- codec(
    "vanishing",
    encode = function(value, path) NULL,
    decode = function(path, meta) {
      stash_delete(s, "k")
      readRDS(path)
    }
  )
  hit$record$codec <- "vanishing"
  s$codecs <- codec_registry(list(vanishing))
  expect_null(store_decode_entry(s, hit, key))
})

test_that("an unreferenced file is reaped only while it is still unreferenced", {
  s <- local_stash(inline_max = 100)
  x <- runif(100)
  stash_set(s, "a", x)
  name <- basename(stash_path(s, "a"))
  # A reap scheduled for a file some record references again does nothing.
  stash_set(s, "b", x)
  blob_reap(s, name)
  expect_true(file.exists(blob_path(s, name)))
  expect_identical(store_violations(s), character())
})

test_that("an orphan of the same name is replaced by the freshly written file", {
  s <- local_stash(inline_max = 100)
  x <- runif(100)
  stash_set(s, "a", x)
  path <- stash_path(s, "a")
  stash_delete(s, "a")
  # A truncated orphan, as a crash might leave it.
  dir.create(dirname(path), showWarnings = FALSE)
  writeBin(as.raw(1:3), path)
  stash_set(s, "a", x)
  expect_identical(stash_get(s, "a"), x)
  expect_identical(store_violations(s), character())
})

# Crashes and processes --------------------------------------------------------

crash_writer <- function(dir, point, fn) {
  callr::r(
    function(dir, fn) {
      s <- dastash::stash(dir, inline_max = 100)
      fn(s)
    },
    args = list(dir = dir, fn = fn),
    env = c(callr::rcmd_safe_env(), DASTASH_CRASH = point),
    error = "error"
  )
}

test_that("a writer killed between publish and commit leaves at most an orphan", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  skip_on_os("windows")
  dir <- withr::local_tempdir()
  expect_error(crash_writer(dir, "publish", function(s) dastash::stash_set(s, "k", runif(100))))
  s <- stash(dir)
  withr::defer(stash_close(s))
  expect_false(stash_has(s, "k"))
  expect_length(blob_files(s), 1L)
  expect_identical(store_violations(s), character())
  stash_set(s, "k", 1)
  expect_identical(stash_get(s, "k"), 1)
})

test_that("a writer killed between commit and unlink leaves at most an orphan", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  skip_on_os("windows")
  dir <- withr::local_tempdir()
  s <- stash(dir, inline_max = 100)
  stash_set(s, "k", runif(100))
  stash_close(s)
  expect_error(crash_writer(dir, "unlink", function(s) dastash::stash_delete(s, "k")))
  s <- stash(dir)
  withr::defer(stash_close(s))
  expect_false(stash_has(s, "k"))
  expect_length(blob_files(s), 1L)
  expect_identical(store_violations(s), character())
})

test_that("eight processes writing the same and different keys keep every invariant", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- stash(dir, inline_max = 100)
  withr::defer(stash_close(s))
  shared <- runif(200)
  jobs <- lapply(1:8, function(i) {
    callr::r_bg(function(dir, i, shared) {
      s <- dastash::stash(dir)
      on.exit(dastash::stash_close(s))
      for (j in 1:15) {
        dastash::stash_set(s, "same", shared)
        dastash::stash_set(s, sprintf("mine-%d", i), runif(200))
        dastash::stash_set(s, sprintf("copy-%d-%d", i, j %% 3), shared)
        if (j %% 4 == 0) dastash::stash_delete(s, sprintf("copy-%d-%d", i, 0))
        stopifnot(identical(dastash::stash_get(s, "same"), shared))
      }
    }, args = list(dir = dir, i = i, shared = shared))
  })
  for (job in jobs) {
    job$wait(timeout = 120000)
    expect_no_error(job$get_result())
  }
  expect_identical(store_violations(s), character())
  expect_identical(stash_get(s, "same"), shared)
  for (path in list.files(file.path(dir, "blobs"), recursive = TRUE, full.names = TRUE)) {
    expect_identical(tools::sha256sum(path)[[1]], sub("\\..*$", "", basename(path)))
  }
  expect_length(list.files(file.path(dir, "tmp")), 0L)
})

test_that("readers never see a dangling file while writers replace and delete", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- stash(dir, inline_max = 100)
  withr::defer(stash_close(s))
  values <- lapply(1:3, function(i) runif(300))
  stash_set(s, "hot", values[[1]])
  writer <- callr::r_bg(function(dir, values) {
    s <- dastash::stash(dir)
    on.exit(dastash::stash_close(s))
    for (j in 1:60) {
      dastash::stash_set(s, "hot", values[[j %% 3 + 1]])
      if (j %% 7 == 0) dastash::stash_delete(s, "hot")
    }
  }, args = list(dir = dir, values = values))
  readers <- lapply(1:4, function(i) {
    callr::r_bg(function(dir, values) {
      s <- dastash::stash(dir)
      on.exit(dastash::stash_close(s))
      seen <- 0
      for (j in 1:150) {
        v <- dastash::stash_get(s, "hot", default = NULL)
        if (!is.null(v)) {
          stopifnot(any(vapply(values, identical, logical(1), v)))
          seen <- seen + 1
        }
      }
      seen
    }, args = list(dir = dir, values = values))
  })
  # get_result() re-raises a child's error, so a failure says what it was.
  writer$wait(timeout = 120000)
  expect_no_error(writer$get_result())
  for (r in readers) {
    r$wait(timeout = 120000)
    expect_no_error(r$get_result())
  }
  expect_identical(store_violations(s), character())
})
