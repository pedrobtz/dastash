# Size limit and eviction --------------------------------------------------------

test_that("writes keep the cache near its limit, evicting the least recently stored", {
  s <- local_cache(size_limit = 20000, inline_max = 1000, cull_limit = 5)
  for (i in 1:30) cache_set(s, sprintf("k%02d", i), runif(250))
  expect_lte(held(s), 20000 + 2100)
  keys <- cache_keys(s)
  # What is left is the most recently stored.
  expect_true("k30" %in% keys)
  expect_false("k01" %in% keys)
  expect_gt(engine_read(s$engine, store_counters)$evictions, 0)
  expect_identical(store_violations(s), character())
})

test_that("cache_mset() keeps the cache near its limit however large the batch", {
  s <- local_cache(size_limit = 1e5, inline_max = 1000)
  values <- stats::setNames(lapply(1:50, function(i) runif(1000)), sprintf("v%02d", 1:50))
  cache_mset(s, values)
  # At most one entry over the limit, as a run of cache_set() calls leaves it.
  expect_lte(held(s), 1e5 + 8100)
  expect_true("v50" %in% cache_keys(s))
  expect_identical(cache_get(s, "v50"), values$v50)
  expect_identical(store_violations(s), character())
})

test_that("cache_cull() finishes the job", {
  # One eviction per write cannot make room for a value three times the size
  # of the others, so the write leaves the cache over its limit.
  s <- local_cache(size_limit = 10000, inline_max = 1000, cull_limit = 1)
  for (i in 1:4) cache_set(s, sprintf("k%02d", i), runif(250))
  cache_set(s, "k05", runif(750))
  expect_gt(held(s), 10000)
  cache_cull(s)
  expect_lte(held(s), 10000)
  expect_true("k05" %in% cache_keys(s))
  expect_identical(store_violations(s), character())
})

test_that("a value larger than the limit is kept and everything else evicted", {
  s <- local_cache(size_limit = 5000, inline_max = 1000, cull_limit = 100)
  for (i in 1:3) cache_set(s, sprintf("small%d", i), runif(100))
  cache_set(s, "huge", runif(2000))
  expect_true(cache_has(s, "huge"))
  expect_identical(cache_keys(s), "huge")
})

test_that("eviction = \"none\" and size_limit = Inf never evict", {
  s <- local_cache(size_limit = 1000, eviction = "none", inline_max = 100)
  for (i in 1:10) cache_set(s, sprintf("k%d", i), runif(100))
  expect_identical(cache_count(s), 10L)
  cache_cull(s)
  expect_identical(cache_count(s), 10L)
  expect_false("stored" %in% names(s$engine$dbs))
})

test_that("culling reclaims expired entries first", {
  s <- local_cache(size_limit = 1e6, inline_max = 1000)
  cache_set(s, "old", runif(100), expire = 0)
  cache_set(s, "kept", runif(100))
  cache_cull(s)
  expect_identical(cache_count(s), 1L)
  expect_identical(cache_keys(s), "kept")
})

# Tags ---------------------------------------------------------------------------

test_that("tags are stored, listed and evicted", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "a", 1, tags = "x")
  cache_set(s, "b", runif(100), tags = c("x", "y"))
  cache_set(s, "c", 3, tags = "y")
  cache_set(s, "d", 4)
  expect_setequal(cache_entries(s, tag = "x")$key, c("a", "b"))
  expect_identical(cache_entries(s, tag = "y")$tags, list(c("x", "y"), "y"))
  cache_evict(s, tag = "x")
  expect_identical(cache_keys(s), c("c", "d"))
  expect_length(list.files(file.path(s$dir, "blobs"), recursive = TRUE), 0L)
  expect_identical(store_violations(s), character())
})

test_that("replacing an entry replaces its tags", {
  s <- local_cache()
  cache_set(s, "a", 1, tags = c("old", "both"))
  cache_set(s, "a", 2, tags = c("both", "new"))
  expect_identical(nrow(cache_entries(s, tag = "old")), 0L)
  expect_identical(cache_entries(s, tag = "new")$key, "a")
  cache_incr(s, "n")
  cache_set(s, "n", 5, tags = "count")
  expect_identical(cache_entries(s, tag = "count")$key, "n")
})

test_that("tags are checked", {
  s <- local_cache()
  expect_error(cache_set(s, "a", 1, tags = NA_character_), class = "dazcache_type_error")
  expect_error(cache_set(s, "a", 1, tags = ""), class = "dazcache_type_error")
  expect_error(cache_set(s, "a", 1, tags = 1), class = "dazcache_type_error")
  expect_error(cache_set(s, "a", 1, tags = paste0("t", 1:17)), class = "dazcache_type_error")
  expect_error(cache_set(s, "a", 1, tags = strrep("t", 257)), class = "dazcache_type_error")
  cache_set(s, "a", 1, tags = c("b", "a", "b"))
  expect_identical(cache_info(s, "a")$tags, list(c("a", "b")))
})

test_that("evict by prefix, and evict needs exactly one selector", {
  s <- local_cache()
  cache_mset(s, list(`p/1` = 1, `p/2` = 2, `q/1` = 3))
  cache_evict(s, prefix = "p/")
  expect_identical(cache_keys(s), "q/1")
  expect_error(cache_evict(s), class = "dazcache_type_error")
  expect_error(cache_evict(s, tag = "a", prefix = "b"), class = "dazcache_type_error")
})

test_that("cache_clear() empties everything and removes every file", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "a", runif(100), tags = "t", expire = 60)
  cache_set(s, "b", 1)
  cache_clear(s)
  expect_identical(cache_count(s), 0L)
  expect_identical(held(s), 0)
  expect_length(list.files(file.path(s$dir, "blobs"), recursive = TRUE), 0L)
  expect_identical(store_violations(s), character())
  cache_set(s, "c", 1)
  expect_identical(cache_get(s, "c"), 1)
})

# Catalogue ------------------------------------------------------------------------

test_that("cache_entries() has one row per live entry and stable columns", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "a", "abc", tags = "t")
  cache_set(s, "b", runif(100), expire = 3600)
  cache_set(s, "gone", 1, expire = 0)
  e <- cache_entries(s)
  expect_s3_class(e, "data.frame")
  expect_identical(class(e), "data.frame")
  expect_named(e, c("key", "bytes", "codec", "inline", "blob", "tags", "shape", "stored", "accessed", "hits", "expires"))
  expect_identical(e$key, c("a", "b"))
  expect_identical(e$inline, c(TRUE, FALSE))
  expect_true(is.na(e$blob[[1]]))
  expect_match(e$blob[[2]], "^[0-9a-f]{64}$")
  expect_true(is.na(e$expires[[1]]))
  expect_s3_class(e$stored, "POSIXct")
  expect_identical(nrow(cache_entries(s, prefix = "b")), 1L)
  expect_identical(nrow(cache_entries(s, n = 1)), 1L)
  expect_identical(nrow(local_cache() |> cache_entries()), 0L)
})

test_that("cache_info() is one row or NULL", {
  s <- local_cache()
  cache_set(s, "a", "text")
  info <- cache_info(s, "a")
  expect_identical(nrow(info), 1L)
  expect_identical(info$codec, "raw")
  expect_null(cache_info(s, "missing"))
})

test_that("cache_stats() is one row", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "a", 1)
  cache_set(s, "b", runif(100))
  st <- cache_stats(s)
  expect_identical(nrow(st), 1L)
  expect_identical(st$count, 2L)
  expect_gt(st$bytes_blob, 0)
  expect_identical(st$eviction, "least-recently-stored")
  expect_identical(st$durability, "safe")
  expect_identical(st$format_version, FORMAT_VERSION)
})

# cache_check() ---------------------------------------------------------------------

test_that("a sound cache has no findings", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "a", runif(100), tags = "t", expire = 60)
  cache_set(s, "b", 1)
  f <- cache_check(s, hash = TRUE)
  expect_identical(nrow(f), 0L)
  expect_named(f, c("kind", "key", "path", "detail", "repaired"))
})

test_that("cache_check() finds and repairs every kind of damage", {
  s <- local_cache(inline_max = 100)
  x <- runif(100)
  cache_set(s, "blob", x, tags = "t", expire = 60)
  cache_set(s, "shared1", runif(100))
  cache_set(s, "shared2", cache_get(s, "shared1"))
  cache_set(s, "inline", 1)
  cache_set(s, "novalue", 2)
  cache_set(s, "nofile", runif(100))
  cache_set(s, "corrupt", runif(100))
  e <- s$engine
  engine_write(e, function(txn) {
    # An orphan index row, a missing one, an orphan value, a missing value.
    engine_put(txn, engine_db(e, "expiry"), index_key(1, "ghost"), raw())
    engine_del(txn, engine_db(e, "tags"), tag_key("t", "blob"))
    engine_put(txn, engine_db(e, "values"), "stray", as.raw(1))
    engine_del(txn, engine_db(e, "values"), "novalue")
    # A drifted refcount and drifted counters.
    name <- basename(cache_path(s, "shared1"))
    row <- record_decode(engine_get(txn, engine_db(e, "blobs"), name))
    row$refs <- 7
    engine_put(txn, engine_db(e, "blobs"), name, record_encode(row))
    store_counters_add(txn, list(bytes_inline = 99, bytes_blob = 7))
    # A file whose blobs row is gone.
    engine_del(txn, engine_db(e, "blobs"), basename(cache_path(s, "blob")))
  })
  nofile <- cache_path(s, "nofile")
  corrupt <- cache_path(s, "corrupt")
  blob_unlink(nofile)
  Sys.chmod(corrupt, "0644")
  writeBin(as.raw(1:5), corrupt)
  orphan <- file.path(s$dir, "blobs", "ab", paste0(strrep("ab", 32), ".rds"))
  dir.create(dirname(orphan), showWarnings = FALSE)
  writeBin(as.raw(1:3), orphan)

  found <- cache_check(s)
  expect_setequal(
    unique(found$kind),
    c("index_orphan", "index_missing", "value_orphan", "value_missing",
      "blob_missing", "blob_corrupt", "blob_orphan", "refcount_drift", "counter_drift")
  )
  expect_false(any(found$repaired))
  expect_true("file present but not counted" %in% found$detail)
  expect_true(any(startsWith(found$detail, "bytes_blob")))
  expect_true(any(startsWith(found$detail, "bytes_inline")))

  fixed <- cache_check(s, repair = TRUE)
  expect_true(all(fixed$repaired))
  expect_identical(nrow(cache_check(s, hash = TRUE)), 0L)
  expect_identical(store_violations(s), character())
  expect_false(file.exists(orphan))
  expect_false(file.exists(corrupt))
  expect_identical(cache_get(s, "blob"), x)
  expect_identical(cache_entries(s, tag = "t")$key, "blob")
  expect_false(any(cache_has(s, c("novalue", "nofile", "corrupt"))))
  expect_true(all(cache_has(s, c("shared1", "shared2", "inline"))))
})

test_that("hash = TRUE finds a file whose bytes changed but not its size", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "k", runif(100))
  path <- cache_path(s, "k")
  bytes <- readBin(path, "raw", file.size(path))
  bytes[length(bytes)] <- xor(bytes[length(bytes)], as.raw(1))
  Sys.chmod(path, "0644")
  writeBin(bytes, path)
  Sys.chmod(path, "0444")
  expect_identical(nrow(cache_check(s)), 0L)
  f <- cache_check(s, hash = TRUE)
  expect_identical(f$kind, "blob_corrupt")
  cache_check(s, repair = TRUE, hash = TRUE)
  expect_false(cache_has(s, "k"))
  expect_identical(store_violations(s), character())
})

test_that("stale staging files of dead processes are reported and removed", {
  skip_on_os("windows")
  skip_if_not_installed("callr")
  s <- local_cache()
  live <- callr::r_bg(function() Sys.sleep(60))
  withr::defer(live$kill())
  # A process that has exited, so its id is certainly not running now.
  dead <- callr::r(function() Sys.getpid())
  old <- file.path(s$dir, "tmp", sprintf("%d-1", dead))
  fresh <- file.path(s$dir, "tmp", sprintf("%d-2", dead))
  busy <- file.path(s$dir, "tmp", sprintf("%d-1", live$get_pid()))
  for (path in c(old, fresh, busy)) writeLines("x", path)
  Sys.setFileTime(old, Sys.time() - 7200)
  Sys.setFileTime(busy, Sys.time() - 7200)
  # A dead process's file is stale however new; a live one's however old.
  f <- cache_check(s)
  expect_setequal(f$kind, "tmp_stale")
  expect_setequal(f$path, c(old, fresh))
  cache_check(s, repair = TRUE)
  expect_false(file.exists(old))
  expect_false(file.exists(fresh))
  expect_true(file.exists(busy))
})

test_that("an encoder that fails or is interrupted leaves no staging file", {
  s <- local_cache(inline_max = 5)
  tmp <- file.path(s$dir, "tmp")
  bad <- codec("bad", encode = function(value, path) {
    writeBin(as.raw(1:10), path)
    stop("broke")
  }, decode = function(path, meta) 1)
  for (i in 1:3) expect_error(cache_set(s, "k", 1, codec = bad), class = "dazcache_codec_error")
  expect_error(cache_mset(s, list(a = 1, b = 2), codec = bad), class = "dazcache_codec_error")
  expect_length(list.files(tmp), 0L)
  stopped <- codec("stopped", encode = function(value, path) {
    writeBin(as.raw(1:10), path)
    rlang::interrupt()
  }, decode = function(path, meta) 1)
  interrupted <- tryCatch(cache_set(s, "k", 1, codec = stopped), interrupt = function(cnd) TRUE)
  expect_true(interrupted)
  interrupted <- tryCatch(cache_mset(s, list(a = 1, b = 2), codec = stopped), interrupt = function(cnd) TRUE)
  expect_true(interrupted)
  expect_length(list.files(tmp), 0L)
  expect_identical(cache_count(s), 0L)
  # Interrupted on its own staging file, a file-backed value of bytes.
  reached <- FALSE
  local_mocked_bindings(hash_bytes = function(bytes) {
    reached <<- TRUE
    rlang::interrupt()
  })
  tryCatch(cache_set(s, "r", as.raw(1:10)), interrupt = function(cnd) NULL)
  expect_true(reached)
  expect_length(list.files(tmp), 0L)
})

test_that("a crash's orphan is reclaimed by repair", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "k", runif(100))
  path <- cache_path(s, "k")
  # What a crash between commit and unlink leaves: no record, no row, a file.
  engine_write(s$engine, function(txn) {
    engine_del(txn, engine_db(s$engine, "meta"), "k")
    engine_del(txn, engine_db(s$engine, "blobs"), basename(path))
    store_counters_add(txn, list(bytes_blob = -file.size(path)))
  })
  engine_write(s$engine, function(txn) engine_clear_db(txn, engine_db(s$engine, "stored")))
  f <- cache_check(s, repair = TRUE)
  expect_true("blob_orphan" %in% f$kind)
  expect_false(file.exists(path))
  expect_identical(store_violations(s), character())
})

test_that("prefix selects digested keys by their text", {
  s <- local_cache()
  long <- paste0("p/", strrep("x", 600))
  longer <- paste0("p/", strrep("y", 5000))
  other <- paste0("q/", strrep("z", 600))
  # A string beginning with `#` is escaped, so it never sorts among digests.
  hash_like <- "#not-a-digest"
  for (k in c("p/a", long, longer, other, hash_like, "p/b")) {
    cache_set(s, k, 1)
  }
  expect_setequal(
    cache_keys(s, prefix = "p/"),
    c("p/a", "p/b", long, paste0("#", cache_key_hash(longer)))
  )
  expect_length(cache_keys(s, prefix = "p/"), 4L)
  expect_identical(
    cache_keys(s, prefix = "p/", n = 2),
    cache_keys(s, prefix = "p/")[1:2]
  )
  expect_identical(cache_keys(s, prefix = "q/"), other)
  expect_identical(cache_keys(s, prefix = "s:#"), cache_key_chr(hash_like))
  expect_length(cache_keys(s, prefix = ""), 6L)
  # A prefix longer than the kept preview cannot be told for an unkept key.
  expect_length(cache_keys(s, prefix = paste0("p/", strrep("y", 300))), 0L)
  expect_identical(nrow(cache_entries(s, prefix = "p/")), 4L)
  cache_set(s, long, 2, tags = "t")
  cache_set(s, "q/plain", 2, tags = "t")
  expect_identical(cache_entries(s, prefix = "p/", tag = "t")$key, long)
  cache_evict(s, prefix = "p/")
  expect_identical(
    sort(cache_keys(s), method = "radix"),
    sort(c(other, cache_key_chr(hash_like), "q/plain"), method = "radix")
  )
  expect_identical(store_violations(s), character())
})

test_that("start pages through a prefix that holds digested keys", {
  s <- local_cache()
  keys <- c(paste0("p/", 1:5), paste0("p/", strrep("x", 600), 1:3))
  for (k in keys) {
    cache_set(s, k, 1)
  }
  all <- cache_keys(s, prefix = "p/")
  expect_setequal(all, keys)
  page1 <- cache_keys(s, prefix = "p/", n = 4)
  last <- page1[[4]]
  page2 <- cache_keys(s, prefix = "p/", start = last, n = 10)
  expect_identical(c(page1, page2[-1L]), all)
})

test_that("cache_evict() removes more entries than one scan holds", {
  s <- local_cache()
  n <- ENGINE_SCAN_CHUNK + 1L
  values <- as.list(seq_len(n))
  cache_mset(s, stats::setNames(values, sprintf("p/%04d", seq_len(n))))
  cache_mset(s, stats::setNames(values, sprintf("t/%04d", seq_len(n))), tags = "many")
  cache_evict(s, prefix = "p/")
  expect_identical(cache_count(s), n)
  cache_evict(s, tag = "many")
  expect_identical(cache_count(s), 0L)
  expect_identical(store_violations(s), character())
})

test_that("cache_evict() by tag ends on tag rows whose entries are gone", {
  s <- local_cache()
  e <- s$engine
  engine_write(e, function(txn) {
    for (i in seq_len(ENGINE_SCAN_CHUNK)) {
      engine_put(txn, engine_db(e, "tags"), tag_key("t", sprintf("ghost%04d", i)), raw())
    }
  })
  cache_set(s, "real", 1, tags = "t")
  cache_evict(s, tag = "t")
  expect_identical(cache_count(s), 0L)
  expect_identical(engine_read(e, function(txn) engine_count(txn, engine_db(e, "tags"))), 0)
})

test_that("the files a transaction releases are reaped in one follow-up", {
  s <- local_cache(inline_max = 100)
  for (i in 1:20) cache_set(s, paste0("k", i), runif(100))
  reaps <- 0
  reap <- blob_reap
  local_mocked_bindings(blob_reap = function(s, names) {
    reaps <<- reaps + 1
    reap(s, names)
  })
  cache_clear(s)
  expect_identical(reaps, 1)
  for (i in 1:20) cache_set(s, paste0("k", i), runif(100))
  cache_evict(s, prefix = "k")
  expect_identical(reaps, 2)
  expect_length(blob_files(s), 0L)
})

test_that("a write that fills the map leaves the cache sound and usable", {
  s <- local_cache(map_size = 2^20, inline_max = 10000, size_limit = Inf)
  # Each batch publishes a file first, then fills the map with an inline value,
  # so the commit that fails has already published a file.
  full <- tryCatch(
    {
      for (i in 1:200) {
        cache_mset(s, stats::setNames(list(runif(5000), runif(1000)), sprintf(c("b%03d", "i%03d"), i)))
      }
      FALSE
    },
    dazcache_store_full = function(cnd) TRUE
  )
  skip_if_not(full, "the map did not fill")
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
  expect_identical(store_violations(s), character())
  cache_evict(s, prefix = "i")
  f <- cache_check(s, repair = TRUE)
  expect_true(all(f$kind %in% "blob_orphan"))
  expect_identical(nrow(cache_check(s)), 0L)
  cache_set(s, "after", 1)
  expect_identical(cache_get(s, "after"), 1)
})

test_that("every index stays a projection of the records through random mutations", {
  withr::local_seed(20261026)
  s <- local_cache(inline_max = 200, size_limit = 20000, cull_limit = 3)
  keys <- sprintf("k%02d", 1:15)
  tags <- c("red", "green", "blue")
  for (step in 1:300) {
    k <- sample(keys, 1L)
    switch(sample(c("set", "set", "delete", "pop", "incr", "expire", "touch", "evict"), 1L),
      set = cache_set(
        s, k, if (runif(1) < 0.5) runif(sample(1:60, 1L)) else sample(letters, 1L),
        tags = sample(tags, sample(0:2, 1L)),
        expire = if (runif(1) < 0.3) sample(c(-1, 3600), 1L)
      ),
      delete = cache_delete(s, k),
      pop = cache_pop(s, k, default = NULL),
      incr = tryCatch(cache_incr(s, paste0("n", k)), dazcache_type_error = function(cnd) NULL),
      expire = cache_expire(s),
      touch = cache_touch(s, k, sample(c(-1, 60), 1L)),
      evict = if (runif(1) < 0.5) cache_evict(s, tag = sample(tags, 1L)) else cache_evict(s, prefix = "k0")
    )
    violations <- store_violations(s)
    if (length(violations) > 0L) {
      fail(sprintf("after step %d: %s", step, paste(violations, collapse = "; ")))
      break
    }
  }
  expect_identical(nrow(cache_check(s)), 0L)
})

test_that("orphan and stale index rows neither stall the walks nor delete live entries (#115)", {
  # Bound the walk: on the unfixed code it loops forever.
  setTimeLimit(elapsed = 30, transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf), add = TRUE)

  s <- local_cache(cull_limit = 2)
  e <- s$engine
  cache_set(s, "live", 1, expire = 3600)
  cache_set(s, "due", 2, expire = 0)
  engine_write(e, function(txn) {
    db <- engine_db(e, "expiry")
    for (k in c("gone1", "gone2", "gone3")) engine_put(txn, db, index_key(1, k), raw())
    # A stale row: an old deadline for an entry whose record expires in an hour.
    engine_put(txn, db, index_key(2, "live"), raw())
  })
  cache_expire(s)
  expect_identical(cache_get(s, "live"), 1)
  expect_false(cache_has(s, "due"))
  expect_identical(cache_stats(s)$expired, 1)
  expect_identical(
    engine_read(e, function(txn) length(engine_scan(txn, engine_db(e, "expiry")))),
    1L
  )

  s <- local_cache(cull_limit = 2, size_limit = 1000)
  e <- s$engine
  engine_write(e, function(txn) {
    db <- engine_db(e, "stored")
    for (k in c("gone1", "gone2", "gone3")) engine_put(txn, db, index_key(1, k), raw())
  })
  for (i in 1:20) cache_set(s, paste0("k", i), strrep("x", 100))
  expect_lte(held(s), 1000)
  cache_cull(s)
  expect_lte(held(s), 1000)
  expect_identical(
    engine_read(e, function(txn) length(engine_scan(txn, engine_db(e, "stored")))),
    as.integer(cache_count(s))
  )
  expect_identical(nrow(cache_check(s)), 0L)
})

test_that("a torn or garbage record is a finding, and reads raise in the taxonomy (#98)", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "g", 1)
  cache_set(s, "w", 2)
  cache_set(s, "b", runif(100))
  cache_set(s, "ok", 3)
  e <- s$engine
  engine_write(e, function(txn) {
    meta <- engine_db(e, "meta")
    engine_put(txn, meta, "g", as.raw(1:5))
    engine_put(txn, meta, "w", record_encode(1:3))
    engine_put(txn, meta, "b", head(engine_get(txn, meta, "b"), 20))
  })
  for (k in c("g", "w", "b")) {
    expect_error(cache_get(s, k), class = "dazcache_engine_error")
  }
  found <- cache_check(s)
  expect_setequal(found$key[found$kind == "record_corrupt"], c("g", "w", "b"))
  cache_check(s, repair = TRUE)
  expect_identical(nrow(cache_check(s, hash = TRUE)), 0L)
  expect_identical(cache_keys(s), "ok")
  expect_identical(store_violations(s), character())

  # Damaged blobs and counters rows.
  cache_set(s, "b2", runif(100))
  name <- basename(cache_path(s, "b2"))
  engine_write(e, function(txn) {
    engine_put(txn, engine_db(e, "blobs"), name, as.raw(9))
    engine_put(txn, NULL, "counters", as.raw(9))
  })
  found <- cache_check(s)
  expect_true(all(c("refcount_drift", "counter_drift") %in% found$kind))
  cache_check(s, repair = TRUE)
  expect_identical(nrow(cache_check(s)), 0L)
  expect_true(cache_has(s, "b2"))
})

test_that("a blob file in the wrong directory is an orphan, and its entry's file is missing (#99)", {
  s <- local_cache(inline_max = 100)
  cache_set(s, "k", runif(100))
  path <- cache_path(s, "k")
  moved <- file.path(s$dir, "blobs", basename(path))
  file.rename(path, moved)
  found <- cache_check(s)
  expect_setequal(found$kind, c("blob_missing", "blob_orphan"))
  expect_identical(found$path[found$kind == "blob_orphan"], moved)
  cache_check(s, repair = TRUE)
  expect_false(file.exists(moved))
  expect_identical(nrow(cache_check(s, hash = TRUE)), 0L)
})

test_that("one repair suffices when an uncounted file is also damaged (#116)", {
  for (damage in c("short", "bytes", "gone")) {
    s <- local_cache(inline_max = 100)
    cache_set(s, "k", runif(100))
    cache_set(s, "k2", cache_get(s, "k"))
    path <- cache_path(s, "k")
    e <- s$engine
    engine_write(e, function(txn) engine_del(txn, engine_db(e, "blobs"), basename(path)))
    Sys.chmod(path, "0644")
    if (damage == "short") writeBin(as.raw(1), path)
    if (damage == "bytes") {
      bytes <- readBin(path, "raw", file.size(path))
      bytes[1] <- xor(bytes[1], as.raw(1))
      writeBin(bytes, path)
    }
    if (damage == "gone") unlink(path)
    Sys.chmod(path, "0444")
    cache_check(s, repair = TRUE, hash = TRUE)
    expect_identical(nrow(cache_check(s, hash = TRUE)), 0L, label = damage)
    expect_false(any(cache_has(s, c("k", "k2"))))
  }
})

test_that("a writable blob is reported and made read-only again (#125)", {
  skip_on_os("windows")
  s <- local_cache(inline_max = 100)
  cache_set(s, "k", runif(100))
  path <- cache_path(s, "k")
  Sys.chmod(path, "0666")
  found <- cache_check(s)
  expect_identical(found$kind, "blob_mode")
  cache_check(s, repair = TRUE)
  expect_identical(format(file.info(path)$mode), "444")
  expect_identical(nrow(cache_check(s)), 0L)
})

test_that("an inline value of the wrong length is a finding that repair removes (#113)", {
  s <- local_cache()
  cache_set(s, "r", as.raw(1:5))
  e <- s$engine
  engine_write(e, function(txn) engine_put(txn, engine_db(e, "values"), "r", as.raw(1)))
  expect_identical(cache_check(s)$kind, "value_corrupt")
  cache_check(s, repair = TRUE)
  expect_false(cache_has(s, "r"))
  expect_identical(nrow(cache_check(s)), 0L)
})

test_that("a staging file left by an earlier process with this PID neither blocks writes nor survives a check (#127)", {
  s <- local_cache(inline_max = 0)
  stale <- file.path(s$dir, "tmp", sprintf("%d-%d", Sys.getpid(), 1:5))
  stale <- c(stale, file.path(s$dir, "tmp", sprintf("%d-1-%d", Sys.getpid(), 1:5)))
  for (p in stale) {
    writeLines("old", p)
    Sys.chmod(p, "0444")
  }
  cache_set(s, "k", runif(10))
  cache_set(s, "j", "text")
  expect_identical(cache_pop(s, "k", default = NULL) |> length(), 10L)
  found <- cache_check(s, repair = TRUE)
  expect_setequal(found$path[found$kind == "tmp_stale"], stale)
  expect_identical(list.files(file.path(s$dir, "tmp")), character())
})
