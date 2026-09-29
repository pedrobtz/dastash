# Opening and sharing -----------------------------------------------------------

test_that("an engine opens, writes, reads and closes", {
  e <- local_engine()
  engine_fill(e, list(a = "1", b = "2"))
  got <- engine_read(e, function(txn) rawToChar(engine_get(txn, NULL, "a")))
  expect_identical(got, "1")
  expect_null(engine_read(e, function(txn) engine_get(txn, NULL, "zz")))
})

test_that("a second open in this process shares the environment, under any spelling", {
  dir <- withr::local_tempdir()
  e1 <- engine_open(file.path(dir, "cache.mdbx"))
  withr::local_dir(dir)
  e2 <- engine_open("cache.mdbx")
  e3 <- engine_open(file.path(".", "cache.mdbx"))
  expect_identical(e1, e2)
  expect_identical(e1, e3)
  expect_identical(e1$refs, 3L)

  expect_false(engine_close(e1))
  expect_false(engine_close(e2))
  expect_true(mdbx::mdbx_env_is_open(e1$env))
  expect_true(engine_close(e3))
  expect_false(mdbx::mdbx_env_is_open(e1$env))
  expect_null(engine_registry[[e1$path]])
})

test_that("a symlinked directory is the same environment", {
  skip_on_os("windows")
  dir <- withr::local_tempdir()
  link <- paste0(dir, "-link")
  file.symlink(dir, link)
  withr::defer(unlink(link))
  e1 <- local_engine(dir = dir)
  e2 <- engine_open(file.path(link, "cache.mdbx"))
  expect_identical(e1, e2)
  engine_close(e2)
})

test_that("a read-only open cannot be joined for writing", {
  dir <- withr::local_tempdir()
  e <- local_engine(dir = dir)
  engine_fill(e, list(a = "1"))
  engine_close(e)
  ro <- local_engine(dir = dir, readonly = TRUE)
  expect_error(engine_open(file.path(dir, "cache.mdbx")), class = "dastash_readonly")
  expect_error(engine_fill(ro, list(b = "2")), class = "dastash_readonly")
})

test_that("durability is reported by the environment's flags", {
  e <- local_engine(durability = "fast")
  expect_true("SAFE_NOSYNC" %in% engine_flags(e))
})

# Named databases --------------------------------------------------------------

test_that("named databases are created once and are independent", {
  e <- local_engine()
  engine_ensure_dbs(e, c("meta", "values"))
  engine_fill(e, list(k = "m"), db = "meta")
  engine_fill(e, list(k = "v"), db = "values")
  got <- engine_read(e, function(txn) {
    c(
      rawToChar(engine_get(txn, engine_db(e, "meta"), "k")),
      rawToChar(engine_get(txn, engine_db(e, "values"), "k"))
    )
  })
  expect_identical(got, c("m", "v"))
  engine_ensure_dbs(e, c("meta", "values", "tags"))
  expect_named(e$dbs, c("meta", "values", "tags"), ignore.order = TRUE)
})

test_that("a read-only handle reads a missing database as empty", {
  dir <- withr::local_tempdir()
  e <- local_engine(dir = dir)
  engine_ensure_dbs(e, "meta")
  engine_fill(e, list(k = "m"), db = "meta")
  engine_close(e)

  ro <- local_engine(dir = dir, readonly = TRUE)
  engine_ensure_dbs(ro, c("meta", "tags"))
  engine_read(ro, function(txn) {
    expect_null(engine_get(txn, engine_db(ro, "tags"), "k"))
    expect_identical(engine_count(txn, engine_db(ro, "tags")), 0)
    expect_identical(engine_scan(txn, engine_db(ro, "tags")), list())
    expect_identical(engine_count(txn, engine_db(ro, "meta")), 1)
  })
})

test_that("a database that was never opened is an internal error", {
  e <- local_engine()
  expect_error(engine_db(e, "nope"), class = "dastash_engine_error")
})

# Records ------------------------------------------------------------------------

test_that("put without overwrite answers FALSE on an existing key", {
  e <- local_engine()
  engine_write(e, function(txn) {
    expect_true(engine_put(txn, NULL, "k", "1", overwrite = FALSE))
    expect_false(engine_put(txn, NULL, "k", "2", overwrite = FALSE))
    expect_true(engine_del(txn, NULL, "k"))
    expect_false(engine_del(txn, NULL, "k"))
  })
})

test_that("counts are exact", {
  e <- local_engine()
  engine_ensure_dbs(e, "meta")
  engine_fill(e, as.list(stats::setNames(letters, letters)), db = "meta")
  expect_identical(engine_read(e, function(txn) engine_count(txn, engine_db(e, "meta"))), 26)
})

# Transactions ---------------------------------------------------------------------

test_that("an error in a write aborts it and passes through unchanged", {
  e <- local_engine()
  expect_error(
    engine_write(e, function(txn) {
      engine_put(txn, NULL, "k", "1")
      abort_type_error("Not a counter.")
    }),
    class = "dastash_type_error"
  )
  expect_null(engine_read(e, function(txn) engine_get(txn, NULL, "k")))
  expect_null(e$txn)
})

test_that("nested writes and reads join the open write transaction", {
  e <- local_engine()
  engine_write(e, function(txn) {
    engine_write(e, function(inner) {
      expect_identical(inner, txn)
      engine_put(inner, NULL, "k", "1")
    })
    # A read inside the write sees the write.
    expect_identical(engine_read(e, function(t) rawToChar(engine_get(t, NULL, "k"))), "1")
  })
  expect_identical(engine_read(e, function(txn) rawToChar(engine_get(txn, NULL, "k"))), "1")
})

test_that("a write inside a read transaction is an internal error", {
  e <- local_engine()
  expect_error(
    engine_read(e, function(txn) engine_write(e, function(t) NULL)),
    class = "dastash_engine_error"
  )
  expect_null(e$txn)
})

test_that("deferred actions run after the commit, and not after an abort", {
  e <- local_engine()
  ran <- character()
  engine_write(e, function(txn) {
    engine_defer(e, function() ran <<- c(ran, "committed"))
    expect_identical(ran, character())
  })
  expect_identical(ran, "committed")

  try(engine_write(e, function(txn) {
    engine_defer(e, function() ran <<- c(ran, "aborted"))
    abort_type_error("no")
  }), silent = TRUE)
  expect_identical(ran, "committed")
  expect_error(engine_defer(e, function() NULL), class = "dastash_engine_error")
})

test_that("a write returns its value, visibly or not", {
  e <- local_engine()
  expect_identical(engine_write(e, function(txn) 42), 42)
  expect_invisible(engine_write(e, function(txn) invisible(1)))
})

# Errors -----------------------------------------------------------------------------

test_that("a full map is dastash_store_full, with the engine's condition as parent", {
  e <- local_engine(map_size = 1024^2)
  cnd <- expect_error(
    engine_write(e, function(txn) {
      for (i in 1:20000) engine_put(txn, NULL, sprintf("k%06d", i), strrep("v", 200))
    }),
    class = "dastash_store_full"
  )
  expect_s3_class(cnd$parent, "mdbx_map_full")
  expect_null(e$txn)
})

test_that("any other engine failure is dastash_engine_error", {
  e <- local_engine()
  # One byte over libmdbx's key limit, which depends on the page size: 2022
  # bytes at 4 KiB pages, 8166 at 16 KiB (macOS arm64).
  too_long <- strrep("k", mdbx::mdbx_limits(engine_info(e)$pagesize)$keysize_max + 1L)
  cnd <- expect_error(
    engine_write(e, function(txn) engine_put(txn, NULL, too_long, "v")),
    class = "dastash_engine_error"
  )
  expect_s3_class(cnd$parent, "mdbx_error")
})

# Scans ----------------------------------------------------------------------------

test_that("a prefix scan stops at the first key past the prefix, across chunks", {
  e <- local_engine()
  keys <- c(sprintf("a/%03d", 1:25), "a0", "b/1", "a", "Z")
  engine_fill(e, as.list(stats::setNames(keys, keys)))
  got <- engine_read(e, function(txn) engine_scan(txn, NULL, prefix = "a/", as = "character", chunk = 4L))
  expect_identical(got, sprintf("a/%03d", 1:25))
  got_raw <- engine_read(e, function(txn) engine_scan(txn, NULL, prefix = "a/", chunk = 3L))
  expect_identical(vapply(got_raw, rawToChar, ""), sprintf("a/%03d", 1:25))
})

test_that("a scan pages from an inclusive start and stops at n", {
  e <- local_engine()
  keys <- sprintf("k%02d", 1:30)
  engine_fill(e, as.list(stats::setNames(keys, keys)))
  engine_read(e, function(txn) {
    expect_identical(engine_scan(txn, NULL, n = 7, as = "character", chunk = 3L), keys[1:7])
    expect_identical(engine_scan(txn, NULL, start = "k10", n = 3, as = "character"), keys[10:12])
    expect_identical(engine_scan(txn, NULL, as = "character", chunk = 4L), keys)
    expect_identical(engine_scan(txn, NULL, n = 2, reverse = TRUE, as = "character"), keys[30:29])
    expect_identical(engine_scan(txn, NULL, prefix = "zz", as = "character"), character())
  })
})

test_that("a scan can return values alongside keys", {
  e <- local_engine()
  engine_fill(e, list(p1 = "one", p2 = "two", q = "three"))
  got <- engine_read(e, function(txn) engine_scan(txn, NULL, prefix = "p", as = "character", values = TRUE, chunk = 1L))
  expect_identical(got$keys, c("p1", "p2"))
  expect_identical(vapply(got$values, rawToChar, ""), c("one", "two"))
})

test_that("binary index keys scan by byte prefix", {
  e <- local_engine()
  engine_write(e, function(txn) {
    for (t in c(-5, 1, 2, 10)) {
      engine_put(txn, NULL, c(enc_f64(t), charToRaw("key")), raw())
    }
  })
  got <- engine_read(e, function(txn) engine_scan(txn, NULL))
  expect_identical(vapply(got, function(k) dec_f64(k[1:8]), 0), c(-5, 1, 2, 10))
})

# Processes --------------------------------------------------------------------

test_that("a forked child cannot use an inherited environment", {
  skip_on_os("windows")
  skip_on_cran()
  e <- local_engine()
  job <- parallel::mcparallel(
    tryCatch(engine_read(e, function(txn) "used"), dastash_forked = function(cnd) "forked")
  )
  expect_identical(parallel::mccollect(job)[[1]], "forked")
})

test_that("a writer in another process makes the lock busy, then free", {
  skip_if_not_installed("callr")
  skip_on_cran()
  dir <- withr::local_tempdir()
  e <- local_engine(dir = dir)
  engine_fill(e, list(k = "0"))
  path <- e$path
  ready <- file.path(dir, "ready")
  holder <- callr::r_bg(
    function(path, ready) {
      env <- mdbx::mdbx_env_open(path, flags = "ACCEDE")
      txn <- mdbx::mdbx_txn_begin(env, write = TRUE)
      file.create(ready)
      Sys.sleep(3)
      mdbx::mdbx_txn_commit(txn)
      mdbx::mdbx_env_close(env)
    },
    args = list(path = path, ready = ready)
  )
  withr::defer(holder$kill())
  for (i in 1:200) if (file.exists(ready)) break else Sys.sleep(0.05)
  expect_true(file.exists(ready))

  expect_error(engine_write(e, function(txn) NULL, timeout = 0.3), class = "dastash_busy")
  # Readers are never blocked.
  expect_identical(engine_read(e, function(txn) rawToChar(engine_get(txn, NULL, "k"))), "0")
  # Waiting long enough gets the lock once the other writer commits.
  expect_identical(engine_write(e, function(txn) "written", timeout = 30), "written")
})
