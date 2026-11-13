test_that("a value of inline_max bytes or more becomes a read-only file", {
  s <- local_cache(inline_max = 1000)
  small <- 1:10
  big <- runif(1000)
  cache_set(s, "small", small)
  cache_set(s, "big", big)
  expect_identical(cache_get(s, "big"), big)
  expect_identical(cache_get(s, "small"), small)
  expect_error(cache_path(s, "small"), class = "dazcache_type_error")
  path <- cache_path(s, "big")
  expect_match(basename(path), "^[0-9a-f]{64}\\.rds$")
  expect_identical(basename(dirname(path)), substr(basename(path), 1, 2))
  expect_identical(readRDS(path), big)
  if (.Platform$OS.type == "unix") expect_identical(format(file.info(path)$mode), "444")
  expect_identical(tools::sha256sum(path)[[1]], sub("\\.rds$", "", basename(path)))
  expect_identical(store_violations(s), character())
})

test_that("identical bytes are one file, kept while any key refers to it", {
  s <- local_cache(inline_max = 100)
  x <- runif(100)
  cache_set(s, "a", x)
  cache_set(s, "b", x)
  expect_identical(cache_path(s, "a"), cache_path(s, "b"))
  expect_length(blob_files(s), 1L)
  cache_delete(s, "a")
  expect_true(file.exists(cache_path(s, "b")))
  expect_identical(cache_get(s, "b"), x)
  cache_delete(s, "b")
  expect_length(blob_files(s), 0L)
  expect_identical(store_violations(s), character())
})

test_that("replacing an entry releases its old file, and the same bytes stay", {
  s <- local_cache(inline_max = 100)
  x <- runif(100)
  y <- runif(100)
  cache_set(s, "k", x)
  old <- cache_path(s, "k")
  cache_set(s, "k", x)
  expect_true(file.exists(old))
  cache_set(s, "k", y)
  expect_false(file.exists(old))
  cache_set(s, "k", "now inline")
  expect_length(blob_files(s), 0L)
  cache_set(s, "k", y)
  expect_length(blob_files(s), 1L)
  expect_identical(store_violations(s), character())
})

test_that("codec_file() stores a copy, with its extension, even when small", {
  s <- local_cache()
  src <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("a,b", "1,2"), src)
  cache_set(s, "table", src, codec = codec_file())
  path <- cache_get(s, "table")
  expect_match(path, "\\.csv$")
  expect_identical(path, cache_path(s, "table"))
  expect_identical(readLines(path), c("a,b", "1,2"))
  unlink(src)
  expect_true(file.exists(path))
})

test_that("pop returns a stored file's value before the file goes", {
  s <- local_cache(inline_max = 100)
  x <- runif(1000)
  cache_set(s, "k", x)
  path <- cache_path(s, "k")
  expect_identical(cache_pop(s, "k"), x)
  expect_false(file.exists(path))
  expect_identical(store_violations(s), character())
})

test_that("staging leaves nothing behind", {
  s <- local_cache(inline_max = 100)
  x <- runif(100)
  cache_set(s, "a", x)
  cache_set(s, "b", x)
  cache_mset(s, list(c = x, d = runif(100)))
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
  expect_error(cache_set(s, "bad", c("a", NA), codec = codec_raw()), class = "dazcache_type_error")
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
})

test_that("volume counts the database and every file once", {
  s <- local_cache(inline_max = 100)
  x <- runif(1000)
  base <- cache_volume(s)
  cache_set(s, "a", x)
  cache_set(s, "b", x)
  one <- file.size(cache_path(s, "a"))
  expect_equal(cache_volume(s) - as.double(engine_info(s$engine)$file_size), one)
  expect_gte(cache_volume(s), base)
})

test_that("a file that is missing or the wrong size is dazcache_blob_corrupt", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "k", runif(100))
  path <- cache_path(s, "k")
  Sys.chmod(path, "0644")
  writeBin(as.raw(1:10), path)
  cnd <- expect_error(cache_get(s, "k"), class = "dazcache_blob_corrupt")
  expect_identical(cnd$path, path)
  unlink(path)
  expect_error(cache_get(s, "k"), class = "dazcache_blob_corrupt")
})

test_that("a file removed with its entry by another writer reads as a miss", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "k", runif(100))
  key <- store_key("k")
  # The read that found the entry, then another writer deletes it.
  hit <- engine_read(s$engine, function(txn) store_read_entry(s, txn, key))
  cache_delete(s, "k")
  expect_null(store_decode_entry(s, hit, key))
})

test_that("a file that vanishes as the decoder opens it reads as a miss", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "k", runif(100))
  key <- store_key("k")
  hit <- engine_read(s$engine, function(txn) store_read_entry(s, txn, key))
  vanishing <- codec(
    "vanishing",
    encode = function(value, path) NULL,
    decode = function(path, meta) {
      cache_delete(s, "k")
      readRDS(path)
    }
  )
  hit$record$codec <- "vanishing"
  s$codecs <- codec_registry(list(vanishing))
  expect_null(store_decode_entry(s, hit, key))
})

test_that("a decode that fails while the file moves is retried", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "k", runif(100))
  key <- store_key("k")
  hit <- engine_read(s$engine, function(txn) store_read_entry(s, txn, key))
  tries <- 0
  flaky <- codec("flaky", encode = function(value, path) NULL, decode = function(path, meta) {
    tries <<- tries + 1
    if (tries < 3) {
      warning("cannot open file")
      stop("cannot open the connection")
    }
    warning("a warning worth keeping")
    readRDS(path)
  })
  hit$record$codec <- "flaky"
  s$codecs <- codec_registry(list(flaky))
  expect_warning(value <- store_decode_entry(s, hit, key), "worth keeping")
  expect_identical(tries, 3)
  expect_identical(value[[1]], cache_get(s, "k"))
})

test_that("a decode that always fails on a file that is there is an error", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "k", runif(100))
  key <- store_key("k")
  hit <- engine_read(s$engine, function(txn) store_read_entry(s, txn, key))
  broken <- codec("broken", encode = function(value, path) NULL, decode = function(path, meta) stop("bad bytes"))
  hit$record$codec <- "broken"
  s$codecs <- codec_registry(list(broken))
  expect_error(store_decode_entry(s, hit, key), class = "dazcache_codec_error")
})

test_that("an unreferenced file is reaped only while it is still unreferenced", {
  s <- local_cache(inline_max = 100)
  x <- runif(100)
  cache_set(s, "a", x)
  name <- basename(cache_path(s, "a"))
  # A reap scheduled for a file some record references again does nothing.
  cache_set(s, "b", x)
  blob_reap(s, name)
  expect_true(file.exists(blob_path(s, name)))
  expect_identical(store_violations(s), character())
})

test_that("an orphan of the same name is replaced by the freshly written file", {
  s <- local_cache(inline_max = 100)
  x <- runif(100)
  cache_set(s, "a", x)
  path <- cache_path(s, "a")
  cache_delete(s, "a")
  # A truncated orphan, as a crash might leave it.
  dir.create(dirname(path), showWarnings = FALSE)
  writeBin(as.raw(1:3), path)
  cache_set(s, "a", x)
  expect_identical(cache_get(s, "a"), x)
  expect_identical(store_violations(s), character())
})

# Crashes and processes --------------------------------------------------------

test_that("a writer killed between publish and commit leaves at most an orphan", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  skip_on_os("windows")
  dir <- withr::local_tempdir()
  expect_killed(crash_writer(dir, "publish", function(s) dazcache::cache_set(s, "k", runif(100))))
  s <- cache(dir)
  withr::defer(cache_close(s))
  expect_false(cache_has(s, "k"))
  expect_length(blob_files(s), 1L)
  expect_identical(store_violations(s), character())
  # What the dead process itself held may be cleared too; the only damage is
  # the orphan, and repair reclaims it.
  kinds <- cache_check(s, repair = TRUE)$kind
  expect_identical(setdiff(kinds, c("reader_stale", "tmp_stale")), "blob_orphan")
  expect_length(blob_files(s), 0L)
  cache_set(s, "k", 1)
  expect_identical(cache_get(s, "k"), 1)
})

test_that("a writer killed between commit and unlink leaves at most an orphan", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  skip_on_os("windows")
  dir <- withr::local_tempdir()
  s <- cache(dir, inline_max = 100)
  cache_set(s, "k", runif(100))
  cache_close(s)
  expect_killed(crash_writer(dir, "unlink", function(s) dazcache::cache_delete(s, "k")))
  s <- cache(dir)
  withr::defer(cache_close(s))
  expect_false(cache_has(s, "k"))
  expect_length(blob_files(s), 1L)
  expect_identical(store_violations(s), character())
  # What the dead process itself held may be cleared too; the only damage is
  # the orphan, and repair reclaims it.
  kinds <- cache_check(s, repair = TRUE)$kind
  expect_identical(setdiff(kinds, c("reader_stale", "tmp_stale")), "blob_orphan")
  expect_length(blob_files(s), 0L)
})

test_that("a writer killed replacing a file its transaction released leaves the file", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  skip_on_os("windows")
  dir <- withr::local_tempdir()
  s <- cache(dir, inline_max = 100)
  x <- runif(100)
  cache_set(s, "a", x)
  cache_close(s)
  # Deleting "a" drops the file's last reference inside the transaction, so
  # storing the same bytes under "b" publishes over the existing file; the
  # transaction never commits, and "a" needs its file afterwards.
  expect_killed(crash_writer(dir, "replace", function(s) {
    dazcache::cache_transact(s, {
      v <- dazcache::cache_get(s, "a")
      dazcache::cache_delete(s, "a")
      dazcache::cache_set(s, "b", v)
    })
  }))
  s <- cache(dir)
  withr::defer(cache_close(s))
  expect_identical(cache_get(s, "a"), x)
  expect_false(cache_has(s, "b"))
  expect_identical(store_violations(s), character())
})

test_that("eight processes writing the same and different keys keep every invariant", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- cache(dir, inline_max = 100)
  withr::defer(cache_close(s))
  shared <- runif(200)
  jobs <- lapply(1:8, function(i) {
    callr::r_bg(function(dir, i, shared) {
      s <- dazcache::cache(dir)
      on.exit(dazcache::cache_close(s))
      for (j in 1:15) {
        dazcache::cache_set(s, "same", shared)
        dazcache::cache_set(s, sprintf("mine-%d", i), runif(200))
        dazcache::cache_set(s, sprintf("copy-%d-%d", i, j %% 3), shared)
        if (j %% 4 == 0) dazcache::cache_delete(s, sprintf("copy-%d-%d", i, 0))
        stopifnot(identical(dazcache::cache_get(s, "same"), shared))
      }
    }, args = list(dir = dir, i = i, shared = shared))
  })
  for (job in jobs) {
    job$wait(timeout = 120000)
    expect_no_error(job$get_result())
  }
  expect_identical(store_violations(s), character())
  expect_identical(cache_get(s, "same"), shared)
  for (path in list.files(file.path(dir, "blobs"), recursive = TRUE, full.names = TRUE)) {
    expect_identical(tools::sha256sum(path)[[1]], sub("\\..*$", "", basename(path)))
  }
  expect_length(list.files(file.path(dir, "tmp")), 0L)
})

test_that("readers never see a dangling file while writers replace and delete", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- cache(dir, inline_max = 100)
  withr::defer(cache_close(s))
  values <- lapply(1:3, function(i) runif(300))
  cache_set(s, "hot", values[[1]])
  writer <- callr::r_bg(function(dir, values) {
    s <- dazcache::cache(dir)
    on.exit(dazcache::cache_close(s))
    for (j in 1:60) {
      dazcache::cache_set(s, "hot", values[[j %% 3 + 1]])
      if (j %% 7 == 0) dazcache::cache_delete(s, "hot")
    }
  }, args = list(dir = dir, values = values))
  readers <- lapply(1:4, function(i) {
    callr::r_bg(function(dir, values) {
      s <- dazcache::cache(dir)
      on.exit(dazcache::cache_close(s))
      seen <- 0
      for (j in 1:150) {
        v <- dazcache::cache_get(s, "hot", default = NULL)
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

test_that("seven readers racing a writer through eviction never see a dangling file", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  # Room for about three values, so nearly every write evicts, and the files
  # of evicted entries are reaped while readers may be decoding them.
  s <- cache(dir, inline_max = 100, size_limit = 7500)
  withr::defer(cache_close(s))
  values <- lapply(1:10, function(i) runif(300))
  writer <- callr::r_bg(function(dir, values) {
    s <- dazcache::cache(dir)
    on.exit(dazcache::cache_close(s))
    for (j in 1:80) dazcache::cache_set(s, sprintf("k%02d", j %% 20), values[[j %% 10 + 1]])
  }, args = list(dir = dir, values = values))
  readers <- lapply(1:7, function(i) {
    callr::r_bg(function(dir, values) {
      s <- dazcache::cache(dir)
      on.exit(dazcache::cache_close(s))
      seen <- 0
      for (j in 1:200) {
        v <- dazcache::cache_get(s, sprintf("k%02d", j %% 20), default = NULL)
        if (!is.null(v)) {
          stopifnot(any(vapply(values, identical, logical(1), v)))
          seen <- seen + 1
        }
      }
      seen
    }, args = list(dir = dir, values = values))
  })
  writer$wait(timeout = 120000)
  expect_no_error(writer$get_result())
  for (r in readers) {
    r$wait(timeout = 120000)
    expect_no_error(r$get_result())
  }
  expect_lte(cache_count(s), 4L)
  expect_identical(store_violations(s), character())
  expect_identical(nrow(cache_check(s, hash = TRUE)), 0L)
})

test_that("a missing or wrong-length inline value is damage, never a value (#113)", {
  s <- local_cache()
  e <- s$engine
  values <- list(r = as.raw(1:5), s = "hello", d = list(1, "a"))
  for (k in names(values)) {
    cache_set(s, paste0(k, "_gone"), values[[k]])
    cache_set(s, paste0(k, "_short"), values[[k]])
  }
  engine_write(e, function(txn) {
    for (k in names(values)) {
      engine_del(txn, engine_db(e, "values"), paste0(k, "_gone"))
      engine_put(txn, engine_db(e, "values"), paste0(k, "_short"), as.raw(1))
    }
  })
  for (k in names(values)) {
    for (damage in c("_gone", "_short")) {
      key <- paste0(k, damage)
      expect_error(cache_get(s, key, default = "D"), class = "dazcache_blob_corrupt")
      expect_error(cache_mget(s, key), class = "dazcache_blob_corrupt")
      expect_error(cache_pop(s, key, default = "D"), class = "dazcache_blob_corrupt")
      expect_true(cache_has(s, key))
    }
  }
})

test_that("writing the same bytes replaces a damaged blob (#114)", {
  s <- local_cache(inline_max = 100)
  x <- runif(100)
  cache_set(s, "a", x)
  path <- cache_path(s, "a")
  Sys.chmod(path, "0644")
  writeBin(as.raw(1), path)
  expect_error(cache_get(s, "a"), class = "dazcache_blob_corrupt")
  cache_set(s, "new", x)
  expect_identical(cache_get(s, "new"), x)
  expect_identical(cache_get(s, "a"), x)
  unlink(path)
  cache_set(s, "third", x)
  expect_identical(cache_get(s, "a"), x)
  expect_identical(nrow(cache_check(s, hash = TRUE)), 0L)
})
