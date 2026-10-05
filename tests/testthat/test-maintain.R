held <- function(s) {
  c <- engine_read(s$engine, store_counters)
  c$bytes_inline + c$bytes_blob
}

# Size limit and eviction --------------------------------------------------------

test_that("writes keep the stash near its limit, evicting the least recently stored", {
  s <- local_stash(size_limit = 20000, inline_max = 1000, cull_limit = 5)
  for (i in 1:30) stash_set(s, sprintf("k%02d", i), runif(250))
  expect_lte(held(s), 20000 + 2100)
  keys <- stash_keys(s)
  # What is left is the most recently stored.
  expect_true("k30" %in% keys)
  expect_false("k01" %in% keys)
  expect_gt(engine_read(s$engine, store_counters)$evictions, 0)
  expect_identical(store_violations(s), character())
})

test_that("stash_cull() finishes the job", {
  s <- local_stash(size_limit = Inf, inline_max = 1000)
  for (i in 1:20) stash_set(s, sprintf("k%02d", i), runif(250))
  stash_close(s)
  s <- local_stash(dir = s$dir)
  # A lower limit cannot be set on an existing stash, so write it directly.
  s$config$size_limit <- 10000
  stash_cull(s)
  expect_lte(held(s), 10000)
  expect_identical(stash_keys(s)[length(stash_keys(s))], "k20")
  expect_identical(store_violations(s), character())
})

test_that("a value larger than the limit is kept and everything else evicted", {
  s <- local_stash(size_limit = 5000, inline_max = 1000, cull_limit = 100)
  for (i in 1:3) stash_set(s, sprintf("small%d", i), runif(100))
  stash_set(s, "huge", runif(2000))
  expect_true(stash_has(s, "huge"))
  expect_identical(stash_keys(s), "huge")
})

test_that("eviction = \"none\" and size_limit = Inf never evict", {
  s <- local_stash(size_limit = 1000, eviction = "none", inline_max = 100)
  for (i in 1:10) stash_set(s, sprintf("k%d", i), runif(100))
  expect_identical(stash_count(s), 10L)
  stash_cull(s)
  expect_identical(stash_count(s), 10L)
  expect_false("stored" %in% names(s$engine$dbs))
})

test_that("culling reclaims expired entries first", {
  s <- local_stash(size_limit = 1e6, inline_max = 1000)
  stash_set(s, "old", runif(100), expire = 0)
  stash_set(s, "kept", runif(100))
  stash_cull(s)
  expect_identical(stash_count(s), 1L)
  expect_identical(stash_keys(s), "kept")
})

# Tags ---------------------------------------------------------------------------

test_that("tags are stored, listed and evicted", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "a", 1, tags = "x")
  stash_set(s, "b", runif(100), tags = c("x", "y"))
  stash_set(s, "c", 3, tags = "y")
  stash_set(s, "d", 4)
  expect_setequal(stash_entries(s, tag = "x")$key, c("a", "b"))
  expect_identical(stash_entries(s, tag = "y")$tags, list(c("x", "y"), "y"))
  stash_evict(s, tag = "x")
  expect_identical(stash_keys(s), c("c", "d"))
  expect_length(list.files(file.path(s$dir, "blobs"), recursive = TRUE), 0L)
  expect_identical(store_violations(s), character())
})

test_that("replacing an entry replaces its tags", {
  s <- local_stash()
  stash_set(s, "a", 1, tags = c("old", "both"))
  stash_set(s, "a", 2, tags = c("both", "new"))
  expect_identical(nrow(stash_entries(s, tag = "old")), 0L)
  expect_identical(stash_entries(s, tag = "new")$key, "a")
  stash_incr(s, "n")
  stash_set(s, "n", 5, tags = "count")
  expect_identical(stash_entries(s, tag = "count")$key, "n")
})

test_that("tags are checked", {
  s <- local_stash()
  expect_error(stash_set(s, "a", 1, tags = NA_character_), class = "dastash_type_error")
  expect_error(stash_set(s, "a", 1, tags = ""), class = "dastash_type_error")
  expect_error(stash_set(s, "a", 1, tags = 1), class = "dastash_type_error")
  expect_error(stash_set(s, "a", 1, tags = paste0("t", 1:17)), class = "dastash_type_error")
  expect_error(stash_set(s, "a", 1, tags = strrep("t", 257)), class = "dastash_type_error")
  stash_set(s, "a", 1, tags = c("b", "a", "b"))
  expect_identical(stash_info(s, "a")$tags, list(c("a", "b")))
})

test_that("evict by prefix, and evict needs exactly one selector", {
  s <- local_stash()
  stash_mset(s, list(`p/1` = 1, `p/2` = 2, `q/1` = 3))
  stash_evict(s, prefix = "p/")
  expect_identical(stash_keys(s), "q/1")
  expect_error(stash_evict(s), class = "dastash_type_error")
  expect_error(stash_evict(s, tag = "a", prefix = "b"), class = "dastash_type_error")
})

test_that("stash_clear() empties everything and removes every file", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "a", runif(100), tags = "t", expire = 60)
  stash_set(s, "b", 1)
  stash_clear(s)
  expect_identical(stash_count(s), 0L)
  expect_identical(held(s), 0)
  expect_length(list.files(file.path(s$dir, "blobs"), recursive = TRUE), 0L)
  expect_identical(store_violations(s), character())
  stash_set(s, "c", 1)
  expect_identical(stash_get(s, "c"), 1)
})

# Catalogue ------------------------------------------------------------------------

test_that("stash_entries() has one row per live entry and stable columns", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "a", "abc", tags = "t")
  stash_set(s, "b", runif(100), expire = 3600)
  stash_set(s, "gone", 1, expire = 0)
  e <- stash_entries(s)
  expect_s3_class(e, "data.frame")
  expect_identical(class(e), "data.frame")
  expect_named(e, c("key", "bytes", "codec", "inline", "blob", "tags", "shape", "stored", "accessed", "hits", "expires"))
  expect_identical(e$key, c("a", "b"))
  expect_identical(e$inline, c(TRUE, FALSE))
  expect_true(is.na(e$blob[[1]]))
  expect_match(e$blob[[2]], "^[0-9a-f]{64}$")
  expect_true(is.na(e$expires[[1]]))
  expect_s3_class(e$stored, "POSIXct")
  expect_identical(nrow(stash_entries(s, prefix = "b")), 1L)
  expect_identical(nrow(stash_entries(s, n = 1)), 1L)
  expect_identical(nrow(local_stash() |> stash_entries()), 0L)
})

test_that("stash_info() is one row or NULL", {
  s <- local_stash()
  stash_set(s, "a", "text")
  info <- stash_info(s, "a")
  expect_identical(nrow(info), 1L)
  expect_identical(info$codec, "raw")
  expect_null(stash_info(s, "missing"))
})

test_that("stash_stats() is one row", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "a", 1)
  stash_set(s, "b", runif(100))
  st <- stash_stats(s)
  expect_identical(nrow(st), 1L)
  expect_identical(st$count, 2L)
  expect_gt(st$bytes_blob, 0)
  expect_identical(st$eviction, "least-recently-stored")
  expect_identical(st$durability, "safe")
  expect_identical(st$format_version, FORMAT_VERSION)
})

# stash_check() ---------------------------------------------------------------------

test_that("a sound stash has no findings", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "a", runif(100), tags = "t", expire = 60)
  stash_set(s, "b", 1)
  f <- stash_check(s, hash = TRUE)
  expect_identical(nrow(f), 0L)
  expect_named(f, c("kind", "key", "path", "detail", "repaired"))
})

test_that("stash_check() finds and repairs every kind of damage", {
  s <- local_stash(inline_max = 100)
  x <- runif(100)
  stash_set(s, "blob", x, tags = "t", expire = 60)
  stash_set(s, "shared1", runif(100))
  stash_set(s, "shared2", stash_get(s, "shared1"))
  stash_set(s, "inline", 1)
  stash_set(s, "novalue", 2)
  stash_set(s, "nofile", runif(100))
  stash_set(s, "corrupt", runif(100))
  e <- s$engine
  engine_write(e, function(txn) {
    # An orphan index row, a missing one, an orphan value, a missing value.
    engine_put(txn, engine_db(e, "expiry"), index_key(1, "ghost"), raw())
    engine_del(txn, engine_db(e, "tags"), tag_key("t", "blob"))
    engine_put(txn, engine_db(e, "values"), "stray", as.raw(1))
    engine_del(txn, engine_db(e, "values"), "novalue")
    # A drifted refcount and drifted counters.
    name <- basename(stash_path(s, "shared1"))
    row <- record_decode(engine_get(txn, engine_db(e, "blobs"), name))
    row$refs <- 7
    engine_put(txn, engine_db(e, "blobs"), name, record_encode(row))
    store_counters_add(txn, list(bytes_inline = 99))
  })
  nofile <- stash_path(s, "nofile")
  corrupt <- stash_path(s, "corrupt")
  blob_unlink(nofile)
  Sys.chmod(corrupt, "0644")
  writeBin(as.raw(1:5), corrupt)
  orphan <- file.path(s$dir, "blobs", "ab", paste0(strrep("ab", 32), ".rds"))
  dir.create(dirname(orphan), showWarnings = FALSE)
  writeBin(as.raw(1:3), orphan)

  found <- stash_check(s)
  expect_setequal(
    unique(found$kind),
    c("index_orphan", "index_missing", "value_orphan", "value_missing",
      "blob_missing", "blob_corrupt", "blob_orphan", "refcount_drift", "counter_drift")
  )
  expect_false(any(found$repaired))

  fixed <- stash_check(s, repair = TRUE)
  expect_true(all(fixed$repaired))
  expect_identical(nrow(stash_check(s, hash = TRUE)), 0L)
  expect_identical(store_violations(s), character())
  expect_false(file.exists(orphan))
  expect_false(file.exists(corrupt))
  expect_identical(stash_get(s, "blob"), x)
  expect_identical(stash_entries(s, tag = "t")$key, "blob")
  expect_false(any(stash_has(s, c("novalue", "nofile", "corrupt"))))
  expect_true(all(stash_has(s, c("shared1", "shared2", "inline"))))
})

test_that("hash = TRUE finds a file whose bytes changed but not its size", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "k", runif(100))
  path <- stash_path(s, "k")
  bytes <- readBin(path, "raw", file.size(path))
  bytes[length(bytes)] <- xor(bytes[length(bytes)], as.raw(1))
  Sys.chmod(path, "0644")
  writeBin(bytes, path)
  expect_identical(nrow(stash_check(s)), 0L)
  f <- stash_check(s, hash = TRUE)
  expect_identical(f$kind, "blob_corrupt")
  stash_check(s, repair = TRUE, hash = TRUE)
  expect_false(stash_has(s, "k"))
  expect_identical(store_violations(s), character())
})

test_that("stale staging files of dead processes are reported and removed", {
  skip_on_os("windows")
  skip_if_not_installed("callr")
  s <- local_stash()
  live <- callr::r_bg(function() Sys.sleep(60))
  withr::defer(live$kill())
  old <- file.path(s$dir, "tmp", "999999-1")
  fresh <- file.path(s$dir, "tmp", "999999-2")
  busy <- file.path(s$dir, "tmp", sprintf("%d-1", live$get_pid()))
  for (path in c(old, fresh, busy)) writeLines("x", path)
  Sys.setFileTime(old, Sys.time() - 7200)
  Sys.setFileTime(busy, Sys.time() - 7200)
  # A dead process's file is stale however new; a live one's however old.
  f <- stash_check(s)
  expect_setequal(f$kind, "tmp_stale")
  expect_setequal(f$path, c(old, fresh))
  stash_check(s, repair = TRUE)
  expect_false(file.exists(old))
  expect_false(file.exists(fresh))
  expect_true(file.exists(busy))
})

test_that("an encoder that fails or is interrupted leaves no staging file", {
  s <- local_stash(inline_max = 5)
  tmp <- file.path(s$dir, "tmp")
  bad <- codec("bad", encode = function(value, path) {
    writeBin(as.raw(1:10), path)
    stop("broke")
  }, decode = function(path, meta) 1)
  for (i in 1:3) expect_error(stash_set(s, "k", 1, codec = bad), class = "dastash_codec_error")
  expect_error(stash_mset(s, list(a = 1, b = 2), codec = bad), class = "dastash_codec_error")
  expect_length(list.files(tmp), 0L)
  stopped <- codec("stopped", encode = function(value, path) {
    writeBin(as.raw(1:10), path)
    rlang::interrupt()
  }, decode = function(path, meta) 1)
  interrupted <- tryCatch(stash_set(s, "k", 1, codec = stopped), interrupt = function(cnd) TRUE)
  expect_true(interrupted)
  interrupted <- tryCatch(stash_mset(s, list(a = 1, b = 2), codec = stopped), interrupt = function(cnd) TRUE)
  expect_true(interrupted)
  expect_length(list.files(tmp), 0L)
  expect_identical(stash_count(s), 0L)
  # Interrupted on its own staging file, a file-backed value of bytes.
  local_mocked_bindings(hash_bytes = function(bytes) rlang::interrupt())
  tryCatch(stash_set(s, "r", as.raw(1:10)), interrupt = function(cnd) NULL)
  expect_length(list.files(tmp), 0L)
})

test_that("a crash's orphan is reclaimed by repair", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "k", runif(100))
  path <- stash_path(s, "k")
  # What a crash between commit and unlink leaves: no record, no row, a file.
  engine_write(s$engine, function(txn) {
    engine_del(txn, engine_db(s$engine, "meta"), "k")
    engine_del(txn, engine_db(s$engine, "blobs"), basename(path))
    store_counters_add(txn, list(bytes_blob = -file.size(path)))
    for (row in index_rows(s, "k", list(expire = Inf, stored = 0, tags = character()))) NULL
  })
  engine_write(s$engine, function(txn) engine_clear_db(txn, engine_db(s$engine, "stored")))
  f <- stash_check(s, repair = TRUE)
  expect_true("blob_orphan" %in% f$kind)
  expect_false(file.exists(path))
  expect_identical(store_violations(s), character())
})

test_that("prefix selects digested keys by their text", {
  s <- local_stash()
  long <- paste0("p/", strrep("x", 600))
  longer <- paste0("p/", strrep("y", 5000))
  other <- paste0("q/", strrep("z", 600))
  # A string beginning with `#` is escaped, so it never sorts among digests.
  hash_like <- "#not-a-digest"
  for (k in c("p/a", long, longer, other, hash_like, "p/b")) {
    stash_set(s, k, 1)
  }
  expect_setequal(
    stash_keys(s, prefix = "p/"),
    c("p/a", "p/b", long, stash_keys(s, prefix = "p/y"))
  )
  expect_length(stash_keys(s, prefix = "p/"), 4L)
  expect_identical(
    stash_keys(s, prefix = "p/", n = 2),
    stash_keys(s, prefix = "p/")[1:2]
  )
  expect_identical(stash_keys(s, prefix = "q/"), other)
  expect_identical(stash_keys(s, prefix = "s:#"), stash_key_chr(hash_like))
  expect_length(stash_keys(s, prefix = ""), 6L)
  # A prefix longer than the kept preview cannot be told for an unkept key.
  expect_length(stash_keys(s, prefix = paste0("p/", strrep("y", 300))), 0L)
  expect_identical(nrow(stash_entries(s, prefix = "p/")), 4L)
  stash_set(s, long, 2, tags = "t")
  stash_set(s, "q/plain", 2, tags = "t")
  expect_identical(stash_entries(s, prefix = "p/", tag = "t")$key, long)
  stash_evict(s, prefix = "p/")
  expect_identical(
    sort(stash_keys(s), method = "radix"),
    sort(c(other, stash_key_chr(hash_like), "q/plain"), method = "radix")
  )
  expect_identical(store_violations(s), character())
})

test_that("start pages through a prefix that holds digested keys", {
  s <- local_stash()
  keys <- c(paste0("p/", 1:5), paste0("p/", strrep("x", 600), 1:3))
  for (k in keys) {
    stash_set(s, k, 1)
  }
  all <- stash_keys(s, prefix = "p/")
  expect_setequal(all, keys)
  page1 <- stash_keys(s, prefix = "p/", n = 4)
  last <- page1[[4]]
  page2 <- stash_keys(s, prefix = "p/", start = last, n = 10)
  expect_identical(c(page1, page2[-1L]), all)
})
