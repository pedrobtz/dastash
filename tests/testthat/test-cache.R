# Opening and closing ------------------------------------------------------------

test_that("cache() creates a directory with the layout of design.md §7.1", {
  dir <- file.path(withr::local_tempdir(), "new", "cache")
  s <- cache(dir)
  withr::defer(cache_close(s))
  expect_true(file.exists(file.path(dir, "cache.mdbx")))
  expect_true(dir.exists(file.path(dir, "blobs")))
  expect_true(dir.exists(file.path(dir, "tmp")))
  expect_identical(cache_dir(s), normalizePath(dir))
  expect_true(cache_is_open(s))
})

test_that("a missing cache is not found when it must not be created", {
  dir <- file.path(withr::local_tempdir(), "absent")
  expect_error(cache(dir, create = FALSE), class = "dazcache_not_found")
  expect_error(cache(dir, readonly = TRUE), class = "dazcache_not_found")
  expect_false(dir.exists(dir))
})

test_that("a directory that cannot be created is a classed error", {
  parent <- withr::local_tempdir()
  # Under a regular file, on every platform and whoever runs the tests.
  file <- file.path(parent, "file")
  writeLines("x", file)
  cnd <- expect_error(cache(file.path(file, "sub")), class = "dazcache_engine_error")
  expect_identical(cnd$dir, file.path(file, "sub"))
  expect_error(cache(file), class = "dazcache_engine_error")
  # Under a directory without write permission.
  skip_on_os("windows")
  skip_if(identical(unname(Sys.info()[["effective_user"]]), "root"), "root can write anywhere")
  locked <- file.path(parent, "locked")
  dir.create(locked)
  Sys.chmod(locked, "0555")
  withr::defer(Sys.chmod(locked, "0755"))
  expect_error(cache(file.path(locked, "sub")), class = "dazcache_engine_error")
})

test_that("closing is idempotent, and a closed cache refuses verbs", {
  s <- cache(withr::local_tempdir())
  expect_invisible(cache_close(s))
  expect_false(cache_is_open(s))
  expect_silent(cache_close(s))
  expect_error(cache_get(s, "a"), class = "dazcache_closed")
  expect_error(cache_set(s, "a", 1), class = "dazcache_closed")
  expect_output(print(s), "closed")
})

test_that("two handles on one directory share it and close separately", {
  dir <- withr::local_tempdir()
  s1 <- cache(dir)
  s2 <- cache(dir)
  expect_identical(s1$engine, s2$engine)
  cache_set(s1, "k", "v")
  expect_identical(cache_get(s2, "k"), "v")
  cache_close(s1)
  expect_identical(cache_get(s2, "k"), "v")
  cache_close(s2)
})

test_that("local_cache() closes on exit and deletes its temporary directory", {
  f <- function() {
    s <- local_cache()
    cache_set(s, "k", 1)
    s
  }
  s <- f()
  expect_false(cache_is_open(s))
  expect_false(dir.exists(s$dir))

  dir <- withr::local_tempdir()
  g <- function() local_cache(dir)
  s2 <- g()
  expect_false(cache_is_open(s2))
  expect_true(dir.exists(dir))
})

test_that("with_cache() passes the cache to a function and closes it", {
  dir <- withr::local_tempdir()
  handle <- NULL
  got <- with_cache(dir, function(s) {
    handle <<- s
    cache_set(s, "k", 42)
    cache_get(s, "k")
  })
  expect_identical(got, 42)
  expect_false(cache_is_open(handle))
})

test_that("arguments are checked", {
  dir <- withr::local_tempdir()
  expect_error(cache(dir, "extra"), class = "dazcache_type_error")
  expect_error(cache(1), class = "dazcache_type_error")
  expect_error(cache(dir, size_limit = -1), class = "dazcache_type_error")
  expect_error(cache(dir, inline_max = 1.5), class = "dazcache_type_error")
  expect_error(cache(dir, timeout = NA), class = "dazcache_type_error")
  expect_error(cache(dir, readonly = "no"), class = "dazcache_type_error")
  expect_error(cache(dir, codec = "rds"), class = "dazcache_codec_error")
  expect_error(cache(dir, eviction = "random"), class = "dazcache_type_error")
  expect_error(cache(dir, eviction = "least-recently-used"), class = "dazcache_unsupported")
})

# Store-level settings -------------------------------------------------------------

test_that("store-level settings persist and conflicts are refused", {
  dir <- withr::local_tempdir()
  s <- cache(dir, size_limit = 1e6, inline_max = 1000, codec = codec_rds())
  cache_close(s)

  s2 <- cache(dir)
  withr::defer(cache_close(s2))
  expect_identical(s2$config$size_limit, 1e6)
  expect_identical(s2$config$inline_max, 1000)
  expect_identical(s2$codec$name, "rds")
  # The same value, given explicitly, is not a conflict.
  s3 <- cache(dir, size_limit = 1e6)
  cache_close(s3)

  expect_error(cache(dir, size_limit = 2e6), class = "dazcache_config_conflict")
  expect_error(cache(dir, inline_max = 10), class = "dazcache_config_conflict")
  expect_error(cache(dir, eviction = "none"), class = "dazcache_config_conflict")
  expect_error(cache(dir, codec = codec_raw()), class = "dazcache_config_conflict")
})

test_that("a store written by a newer format is refused", {
  dir <- withr::local_tempdir()
  s <- cache(dir)
  engine_write(s$engine, function(txn) {
    format <- record_decode(engine_get(txn, NULL, "format"))
    format$format_version <- FORMAT_VERSION + 1L
    engine_put(txn, NULL, "format", record_encode(format))
  })
  cache_close(s)
  expect_error(cache(dir), class = "dazcache_version_unsupported")
})

test_that("a read-only handle reads and refuses writes", {
  dir <- withr::local_tempdir()
  s <- cache(dir)
  cache_set(s, "k", "v")
  cache_close(s)

  ro <- cache(dir, readonly = TRUE)
  withr::defer(cache_close(ro))
  expect_identical(cache_get(ro, "k"), "v")
  expect_error(cache_set(ro, "k", "w"), class = "dazcache_readonly")
  expect_error(cache_delete(ro, "k"), class = "dazcache_readonly")
  expect_output(print(ro), "read-only")
})

test_that("a directory that is not a cache is refused read-only", {
  dir <- withr::local_tempdir()
  e <- engine_open(file.path(dir, "cache.mdbx"))
  engine_close(e)
  expect_error(cache(dir, readonly = TRUE), class = "dazcache_not_found")
})

# Reading and writing ------------------------------------------------------------

test_that("values round-trip through the cache", {
  s <- local_cache()
  values <- list(
    1, 1:3, "text", c("a", "b"), NA, NULL, list(a = 1, b = list(2)),
    as.raw(1:10), data.frame(x = 1:3, y = letters[1:3]),
    factor("a"), as.POSIXct("2026-08-29 10:00", tz = "UTC")
  )
  for (i in seq_along(values)) {
    key <- paste0("k", i)
    cache_set(s, key, values[[i]])
    expect_identical(cache_get(s, key), values[[i]], label = key)
  }
})

test_that("a stored NULL is a value, not a miss", {
  s <- local_cache()
  cache_set(s, "nothing", NULL)
  expect_true(cache_has(s, "nothing"))
  expect_null(cache_get(s, "nothing"))
})

test_that("a miss is an error without default and default with it", {
  s <- local_cache()
  cnd <- expect_error(cache_get(s, "nope"), class = "dazcache_not_found")
  expect_identical(cnd$key, "nope")
  expect_match(conditionMessage(cnd), "Supply `default`")
  expect_null(cache_get(s, "nope", default = NULL))
  expect_identical(cache_get(s, "nope", default = 0), 0)
})

test_that("set replaces, and delete removes", {
  s <- local_cache()
  cache_set(s, "k", 1)
  cache_set(s, "k", 2)
  expect_identical(cache_get(s, "k"), 2)
  expect_identical(cache_count(s), 1L)
  cache_delete(s, c("k", "never-there"))
  expect_false(cache_has(s, "k"))
  expect_identical(cache_count(s), 0L)
})

test_that("any key the encoding covers addresses an entry", {
  s <- local_cache()
  k <- cache_key(exchange = "XSWX", date = as.Date("2026-08-29"))
  cache_set(s, k, "quotes")
  expect_identical(cache_get(s, list(date = as.Date("2026-08-29"), exchange = "XSWX")), "quotes")
  expect_identical(cache_keys(s), "{date=d:2026-08-29,exchange=s:XSWX}")
  cache_set(s, 1L, "one")
  expect_identical(cache_get(s, 1), "one")
})

test_that("a long key is stored digested and listed by its text", {
  s <- local_cache()
  long <- strrep("x", 1000)
  huge <- strrep("y", 5000)
  cache_set(s, long, "long")
  cache_set(s, huge, "huge")
  expect_identical(cache_get(s, long), "long")
  expect_identical(cache_get(s, huge), "huge")
  keys <- cache_keys(s)
  expect_true(long %in% keys)
  # Past CANON_KEEP_MAX the text is not kept, so the digest form is listed.
  expect_true(paste0("#", cache_key_hash(huge)) %in% keys)
})

test_that("mget and mset work on several keys at once", {
  s <- local_cache()
  cache_mset(s, list(a = 1, b = "two"))
  expect_identical(cache_mget(s, c("b", "a")), list(b = "two", a = 1))
  expect_identical(cache_mget(s, c("a", "z"), default = NA), list(a = 1, z = NA))
  cnd <- expect_error(cache_mget(s, c("a", "y", "z")), class = "dazcache_not_found")
  expect_match(conditionMessage(cnd), "and 1 more")
  expect_error(cache_mset(s, list(1, 2)), class = "dazcache_type_error")
  expect_invisible(cache_mset(s, list()))
})

test_that("has is vectorised over keys of any kind", {
  s <- local_cache()
  cache_set(s, "a", 1)
  cache_set(s, 2L, 1)
  expect_identical(cache_has(s, c("a", "b")), c(TRUE, FALSE))
  expect_identical(cache_has(s, list("a", 2, cache_key("a"))), c(TRUE, TRUE, TRUE))
  expect_identical(cache_has(s, cache_key("a")), TRUE)
  expect_identical(cache_has(s, character()), logical())
})

test_that("keys scan by prefix and page from an inclusive start", {
  s <- local_cache()
  keys <- c(sprintf("p/%02d", 1:12), "q/1", "o/1")
  cache_mset(s, stats::setNames(as.list(seq_along(keys)), keys))
  expect_identical(cache_keys(s, prefix = "p/"), sprintf("p/%02d", 1:12))
  expect_identical(cache_keys(s, prefix = "p/", n = 3), sprintf("p/%02d", 1:3))
  expect_identical(cache_keys(s, start = "p/05", n = 2), c("p/05", "p/06"))
  expect_identical(cache_keys(s, prefix = "none/"), character())
  expect_identical(cache_count(s), length(keys))
})

test_that("verbs chain and return the cache invisibly", {
  s <- local_cache()
  expect_invisible(cache_set(s, "a", 1))
  out <- s |> cache_set("a", 1) |> cache_mset(list(b = 2)) |> cache_delete("a")
  expect_identical(out, s)
  expect_identical(cache_keys(s), "b")
})

test_that("inline bytes are counted", {
  s <- local_cache()
  cache_set(s, "a", "abc")
  cache_set(s, "b", "de")
  counters <- engine_read(s$engine, store_counters)
  expect_identical(counters$bytes_inline, 5)
  cache_set(s, "a", "x")
  cache_delete(s, "b")
  expect_identical(engine_read(s$engine, store_counters)$bytes_inline, 1)
})

# User codecs ------------------------------------------------------------------

test_that("a user codec writes and reads through a file", {
  s <- local_cache(codecs = list(lines_codec()))
  cache_set(s, "k", c("a", "b"), codec = lines_codec())
  expect_identical(cache_get(s, "k"), c("a", "b"))
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
})

test_that("an entry by an unknown codec is refused on read, with the codec named", {
  dir <- withr::local_tempdir()
  s <- cache(dir, codecs = list(lines_codec()))
  cache_set(s, "k", "a", codec = lines_codec())
  cache_close(s)
  s2 <- cache(dir)
  withr::defer(cache_close(s2))
  cnd <- expect_error(cache_get(s2, "k"), class = "dazcache_codec_error")
  expect_identical(cnd$codec, "lines")
})

test_that("a user default codec is needed to write but not to read", {
  dir <- withr::local_tempdir()
  s <- cache(dir, codec = lines_codec(), codecs = list(lines_codec()))
  cache_set(s, "k", "a")
  cache_close(s)
  s2 <- cache(dir, readonly = TRUE)
  expect_error(cache_get(s2, "k"), class = "dazcache_codec_error")
  # A process cannot hold a directory read-only and writable at once.
  expect_error(cache(dir), class = "dazcache_readonly")
  cache_close(s2)
  s3 <- cache(dir, codecs = list(lines_codec()))
  withr::defer(cache_close(s3))
  expect_identical(cache_get(s3, "k"), "a")
  s4 <- cache(dir)
  withr::defer(cache_close(s4))
  expect_error(cache_set(s4, "j", "b"), class = "dazcache_codec_error")
  cache_set(s4, "j", 1, codec = codec_rds())
  expect_identical(cache_get(s4, "j"), 1)
})

# Processes --------------------------------------------------------------------

# The one cross-process test that runs on CRAN too: two processes, one key
# each, about a second (roadmap.md §3).
test_that("another process reads what this one wrote", {
  skip_unless_children_see_this_build()
  dir <- withr::local_tempdir()
  s <- cache(dir)
  withr::defer(cache_close(s))
  cache_set(s, "from-parent", list(n = 1:3))
  got <- callr::r(
    function(dir) {
      s <- dazcache::cache(dir)
      on.exit(dazcache::cache_close(s))
      dazcache::cache_set(s, "from-child", "hello")
      dazcache::cache_get(s, "from-parent")
    },
    args = list(dir = dir)
  )
  expect_identical(got, list(n = 1:3))
  expect_identical(cache_get(s, "from-child"), "hello")
})

test_that("a named list, a data frame or a POSIXlt is one key to every verb", {
  s <- local_cache()
  keys <- list(list(n = 1), data.frame(x = 1:2), as.POSIXlt("2026-08-29 10:00:00", tz = "UTC"))
  for (key in keys) {
    cache_set(s, key, "one")
    expect_true(cache_has(s, key))
    expect_identical(unname(cache_mget(s, key)), list("one"))
    cache_delete(s, key)
    expect_false(cache_has(s, key))
  }
  cache_set(s, 1, "number")
  expect_identical(cache_has(s, list(1, list(n = 1))), c(TRUE, FALSE))
})

test_that("start pages forward through structured keys", {
  s <- local_cache()
  for (i in 1:5) cache_set(s, list(n = i), i)
  seen <- character()
  page <- cache_keys(s, n = 2)
  repeat {
    seen <- c(seen, page)
    if (length(page) < 2L || length(seen) > 10L) break
    page <- cache_keys(s, start = page[[length(page)]], n = 3)[-1L]
  }
  expect_identical(seen, cache_keys(s))
  expect_identical(cache_keys(s, start = cache_key(n = 4)), cache_keys(s)[4:5])
})

test_that("reopening a store creates only the indexes its stored settings use", {
  dir <- withr::local_tempdir()
  s0 <- cache(dir, eviction = "none")
  cache_close(s0)
  local_mocked_bindings(engine_begin_write = function(...) stop("took the write lock"))
  s <- local_cache(dir)
  expect_identical(s$config$eviction, "none")
  dbs <- engine_read(s$engine, function(txn) mdbx::mdbx_dbi_list(txn))
  expect_false("stored" %in% dbs)
})

test_that("a handle reads back what its own default codec wrote", {
  s <- local_cache(codec = lines_codec())
  cache_set(s, "a", c("x", "y"))
  expect_identical(cache_get(s, "a"), c("x", "y"))
  cache_set(s, "b", "z", codec = codec_rds())
  cache_set(s, "c", c("p", "q"), codec = lines_codec())
  expect_identical(cache_get(s, "c"), c("p", "q"))
})

test_that("a missing required argument is a dazcache_type_error", {
  s <- local_cache()
  expect_error(cache_get(s), class = "dazcache_type_error")
  expect_error(cache_get(), class = "dazcache_type_error")
  expect_error(cache_set(s, "a"), class = "dazcache_type_error")
  expect_error(cache_touch(s, "a"), class = "dazcache_type_error")
  expect_error(cache_has(s), class = "dazcache_type_error")
  expect_error(cache_transact(s), class = "dazcache_type_error")
  expect_error(cache_count(), class = "dazcache_type_error")
  expect_error(cache(), class = "dazcache_type_error")
  expect_error(with_cache(withr::local_tempdir(), 1), class = "dazcache_type_error")
  expect_error(cache_memoise(identity), class = "dazcache_type_error")
})

test_that("a key error names the verb that was called", {
  s <- local_cache()
  f <- function() cache_has(s, list(function() 1))
  err <- tryCatch(f(), dazcache_key_invalid = function(cnd) cnd)
  expect_identical(err$call[[1L]], quote(cache_has))
  err <- tryCatch(cache_delete(s, environment()), dazcache_type_error = function(cnd) cnd)
  expect_identical(err$call[[1L]], quote(cache_delete))
})

test_that("a forked worker opens a directory its parent has open (#96)", {
  skip_on_os("windows")
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- cache(dir)
  withr::defer(cache_close(s))
  cache_set(s, "k", "v")
  worker <- function() {
    w <- cache(dir)
    on.exit(cache_close(w))
    cache_get(w, "k", default = "miss")
  }
  jobs <- list(parallel::mcparallel(worker()), parallel::mcparallel(worker()))
  got <- parallel::mccollect(jobs)
  expect_identical(unname(unlist(got)), c("v", "v"))
  expect_identical(cache_get(s, "k"), "v")
})

test_that("every numeric and choice argument is refused in the taxonomy (#94, #112)", {
  s <- local_cache()
  dir <- withr::local_tempdir()
  f <- function(x) x
  bad <- list(
    quote(cache(dir, cull_limit = 3e9)),
    quote(cache(dir, cull_limit = .Machine$integer.max + 1)),
    quote(cache(dir, cull_limit = 0.5)),
    quote(cache(dir, cull_limit = NA)),
    quote(cache(dir, map_size = 4096)),
    quote(cache(dir, map_size = 1e6 + 0.5)),
    quote(cache(dir, map_size = Inf)),
    quote(cache(dir, timeout = -1)),
    quote(cache(dir, timeout = NA)),
    quote(cache(dir, inline_max = -1)),
    quote(cache(dir, inline_max = Inf)),
    quote(cache(dir, size_limit = -1)),
    quote(cache(dir, size_limit = "1")),
    quote(cache(dir, eviction = "lru")),
    quote(cache(dir, eviction = c("none", "least-recently-stored"))),
    quote(cache(dir, durability = 1)),
    quote(cache(dir, durability = NA_character_)),
    quote(cache_incr(s, "c", 5)),
    quote(cache_keys(s, n = -1)),
    quote(cache_keys(s, n = 0.5)),
    quote(cache_memoise(f, s, version = 2^53 + 2)),
    quote(cache_memoise(f, s, version = -1)),
    quote(cache_set(s, "k", 1, expire = NA)),
    quote(cache_set(s, "k", 1, expire = "1h"))
  )
  for (call in bad) {
    expect_error(eval(call), class = "dazcache_type_error", label = deparse(call))
  }
  expect_true(cache_is_open(local_cache(cull_limit = .Machine$integer.max)))
  expect_true(cache_is_open(local_cache(map_size = 2^18)))
  t <- local_cache(timeout = Inf)
  cache_set(t, "k", 1)
  expect_identical(cache_get(t, "k"), 1)
})

test_that("a memoised version past the integer range keys exactly (#112)", {
  s <- local_cache()
  f <- function(x) x
  a <- cache_memoise(f, s, version = 20261113120000)
  b <- cache_memoise(f, s, version = 20261113120001)
  a(1)
  b(1)
  expect_setequal(
    cache_keys(s),
    c("f/v20261113120000/{x=i:1}", "f/v20261113120001/{x=i:1}")
  )
})

test_that("print() reads the same in a hostile session (#111)", {
  s <- local_cache()
  for (i in 1:1500) cache_set(s, paste0("k", i), i)
  plain <- format(s)
  withr::local_options(OutDec = ",", scipen = -5, digits = 3, warn = 2)
  expect_identical(format(s), plain)
  expect_match(plain[[2]], "entries 1500 ", fixed = TRUE)
  expect_error(cache(withr::local_tempdir(), timeout = -1), "at least 0,", class = "dazcache_type_error")
})
