# Opening and closing ------------------------------------------------------------

test_that("stash() creates a directory with the layout of design.md §7.1", {
  dir <- file.path(withr::local_tempdir(), "new", "stash")
  s <- stash(dir)
  withr::defer(stash_close(s))
  expect_true(file.exists(file.path(dir, "cache.mdbx")))
  expect_true(dir.exists(file.path(dir, "blobs")))
  expect_true(dir.exists(file.path(dir, "tmp")))
  expect_identical(stash_dir(s), normalizePath(dir))
  expect_true(stash_is_open(s))
})

test_that("a missing stash is not found when it must not be created", {
  dir <- file.path(withr::local_tempdir(), "absent")
  expect_error(stash(dir, create = FALSE), class = "dastash_not_found")
  expect_error(stash(dir, readonly = TRUE), class = "dastash_not_found")
  expect_false(dir.exists(dir))
})

test_that("closing is idempotent, and a closed stash refuses verbs", {
  s <- stash(withr::local_tempdir())
  expect_invisible(stash_close(s))
  expect_false(stash_is_open(s))
  expect_silent(stash_close(s))
  expect_error(stash_get(s, "a"), class = "dastash_closed")
  expect_error(stash_set(s, "a", 1), class = "dastash_closed")
  expect_output(print(s), "closed")
})

test_that("two handles on one directory share it and close separately", {
  dir <- withr::local_tempdir()
  s1 <- stash(dir)
  s2 <- stash(dir)
  expect_identical(s1$engine, s2$engine)
  stash_set(s1, "k", "v")
  expect_identical(stash_get(s2, "k"), "v")
  stash_close(s1)
  expect_identical(stash_get(s2, "k"), "v")
  stash_close(s2)
})

test_that("local_stash() closes on exit and deletes its temporary directory", {
  f <- function() {
    s <- local_stash()
    stash_set(s, "k", 1)
    s
  }
  s <- f()
  expect_false(stash_is_open(s))
  expect_false(dir.exists(s$dir))

  dir <- withr::local_tempdir()
  g <- function() local_stash(dir)
  s2 <- g()
  expect_false(stash_is_open(s2))
  expect_true(dir.exists(dir))
})

test_that("with_stash() passes the stash to a function and closes it", {
  dir <- withr::local_tempdir()
  handle <- NULL
  got <- with_stash(dir, function(s) {
    handle <<- s
    stash_set(s, "k", 42)
    stash_get(s, "k")
  })
  expect_identical(got, 42)
  expect_false(stash_is_open(handle))
})

test_that("arguments are checked", {
  dir <- withr::local_tempdir()
  expect_error(stash(dir, "extra"), class = "rlib_error_dots_nonempty")
  expect_error(stash(1), class = "dastash_type_error")
  expect_error(stash(dir, size_limit = -1), class = "dastash_type_error")
  expect_error(stash(dir, inline_max = 1.5), class = "dastash_type_error")
  expect_error(stash(dir, timeout = NA), class = "dastash_type_error")
  expect_error(stash(dir, readonly = "no"), class = "dastash_type_error")
  expect_error(stash(dir, codec = "rds"), class = "dastash_codec_error")
  expect_error(stash(dir, eviction = "random"), class = "rlang_error")
  expect_error(stash(dir, eviction = "least-recently-used"), class = "dastash_unsupported")
})

# Store-level settings -------------------------------------------------------------

test_that("store-level settings persist and conflicts are refused", {
  dir <- withr::local_tempdir()
  s <- stash(dir, size_limit = 1e6, inline_max = 1000, codec = codec_rds())
  stash_close(s)

  s2 <- stash(dir)
  withr::defer(stash_close(s2))
  expect_identical(s2$config$size_limit, 1e6)
  expect_identical(s2$config$inline_max, 1000)
  expect_identical(s2$codec$name, "rds")
  # The same value, given explicitly, is not a conflict.
  s3 <- stash(dir, size_limit = 1e6)
  stash_close(s3)

  expect_error(stash(dir, size_limit = 2e6), class = "dastash_config_conflict")
  expect_error(stash(dir, inline_max = 10), class = "dastash_config_conflict")
  expect_error(stash(dir, eviction = "none"), class = "dastash_config_conflict")
  expect_error(stash(dir, codec = codec_raw()), class = "dastash_config_conflict")
})

test_that("a store written by a newer format is refused", {
  dir <- withr::local_tempdir()
  s <- stash(dir)
  engine_write(s$engine, function(txn) {
    format <- record_decode(engine_get(txn, NULL, "format"))
    format$format_version <- FORMAT_VERSION + 1L
    engine_put(txn, NULL, "format", record_encode(format))
  })
  stash_close(s)
  expect_error(stash(dir), class = "dastash_version_unsupported")
})

test_that("a read-only handle reads and refuses writes", {
  dir <- withr::local_tempdir()
  s <- stash(dir)
  stash_set(s, "k", "v")
  stash_close(s)

  ro <- stash(dir, readonly = TRUE)
  withr::defer(stash_close(ro))
  expect_identical(stash_get(ro, "k"), "v")
  expect_error(stash_set(ro, "k", "w"), class = "dastash_readonly")
  expect_error(stash_delete(ro, "k"), class = "dastash_readonly")
  expect_output(print(ro), "read-only")
})

test_that("a directory that is not a stash is refused read-only", {
  dir <- withr::local_tempdir()
  e <- engine_open(file.path(dir, "cache.mdbx"))
  engine_close(e)
  expect_error(stash(dir, readonly = TRUE), class = "dastash_not_found")
})

# Reading and writing ------------------------------------------------------------

test_that("values round-trip through the stash", {
  s <- local_stash()
  values <- list(
    1, 1:3, "text", c("a", "b"), NA, NULL, list(a = 1, b = list(2)),
    as.raw(1:10), data.frame(x = 1:3, y = letters[1:3]),
    factor("a"), as.POSIXct("2026-08-29 10:00", tz = "UTC")
  )
  for (i in seq_along(values)) {
    key <- paste0("k", i)
    stash_set(s, key, values[[i]])
    expect_identical(stash_get(s, key), values[[i]], label = key)
  }
})

test_that("a stored NULL is a value, not a miss", {
  s <- local_stash()
  stash_set(s, "nothing", NULL)
  expect_true(stash_has(s, "nothing"))
  expect_null(stash_get(s, "nothing"))
})

test_that("a miss is an error without default and default with it", {
  s <- local_stash()
  cnd <- expect_error(stash_get(s, "nope"), class = "dastash_not_found")
  expect_identical(cnd$key, "nope")
  expect_match(conditionMessage(cnd), "Supply `default`")
  expect_null(stash_get(s, "nope", default = NULL))
  expect_identical(stash_get(s, "nope", default = 0), 0)
})

test_that("set replaces, and delete removes", {
  s <- local_stash()
  stash_set(s, "k", 1)
  stash_set(s, "k", 2)
  expect_identical(stash_get(s, "k"), 2)
  expect_identical(stash_count(s), 1L)
  stash_delete(s, c("k", "never-there"))
  expect_false(stash_has(s, "k"))
  expect_identical(stash_count(s), 0L)
})

test_that("any key the encoding covers addresses an entry", {
  s <- local_stash()
  k <- stash_key(exchange = "XSWX", date = as.Date("2026-08-29"))
  stash_set(s, k, "quotes")
  expect_identical(stash_get(s, list(date = as.Date("2026-08-29"), exchange = "XSWX")), "quotes")
  expect_identical(stash_keys(s), "{date=d:2026-08-29,exchange=s:XSWX}")
  stash_set(s, 1L, "one")
  expect_identical(stash_get(s, 1), "one")
})

test_that("a long key is stored digested and listed by its text", {
  s <- local_stash()
  long <- strrep("x", 1000)
  huge <- strrep("y", 5000)
  stash_set(s, long, "long")
  stash_set(s, huge, "huge")
  expect_identical(stash_get(s, long), "long")
  expect_identical(stash_get(s, huge), "huge")
  keys <- stash_keys(s)
  expect_true(long %in% keys)
  # Past CANON_KEEP_MAX the text is not kept, so the digest form is listed.
  expect_true(paste0("#", stash_key_hash(huge)) %in% keys)
})

test_that("mget and mset work on several keys at once", {
  s <- local_stash()
  stash_mset(s, list(a = 1, b = "two"))
  expect_identical(stash_mget(s, c("b", "a")), list(b = "two", a = 1))
  expect_identical(stash_mget(s, c("a", "z"), default = NA), list(a = 1, z = NA))
  cnd <- expect_error(stash_mget(s, c("a", "y", "z")), class = "dastash_not_found")
  expect_match(conditionMessage(cnd), "and 1 more")
  expect_error(stash_mset(s, list(1, 2)), class = "dastash_type_error")
  expect_invisible(stash_mset(s, list()))
})

test_that("has is vectorised over keys of any kind", {
  s <- local_stash()
  stash_set(s, "a", 1)
  stash_set(s, 2L, 1)
  expect_identical(stash_has(s, c("a", "b")), c(TRUE, FALSE))
  expect_identical(stash_has(s, list("a", 2, stash_key("a"))), c(TRUE, TRUE, TRUE))
  expect_identical(stash_has(s, stash_key("a")), TRUE)
  expect_identical(stash_has(s, character()), logical())
})

test_that("keys scan by prefix and page from an inclusive start", {
  s <- local_stash()
  keys <- c(sprintf("p/%02d", 1:12), "q/1", "o/1")
  stash_mset(s, stats::setNames(as.list(seq_along(keys)), keys))
  expect_identical(stash_keys(s, prefix = "p/"), sprintf("p/%02d", 1:12))
  expect_identical(stash_keys(s, prefix = "p/", n = 3), sprintf("p/%02d", 1:3))
  expect_identical(stash_keys(s, start = "p/05", n = 2), c("p/05", "p/06"))
  expect_identical(stash_keys(s, prefix = "none/"), character())
  expect_identical(stash_count(s), length(keys))
})

test_that("verbs chain and return the stash invisibly", {
  s <- local_stash()
  expect_invisible(stash_set(s, "a", 1))
  out <- s |> stash_set("a", 1) |> stash_mset(list(b = 2)) |> stash_delete("a")
  expect_identical(out, s)
  expect_identical(stash_keys(s), "b")
})

test_that("values of inline_max or more are not stored yet", {
  s <- local_stash(inline_max = 100)
  expect_error(stash_set(s, "big", runif(100)), class = "dastash_unsupported")
  expect_false(stash_has(s, "big"))
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
  expect_error(stash_set(s, "f", withr::local_tempfile(lines = "x"), codec = codec_file()), class = "dastash_unsupported")
})

test_that("inline bytes are counted", {
  s <- local_stash()
  stash_set(s, "a", "abc")
  stash_set(s, "b", "de")
  counters <- engine_read(s$engine, store_counters)
  expect_identical(counters$bytes_inline, 5)
  stash_set(s, "a", "x")
  stash_delete(s, "b")
  expect_identical(engine_read(s$engine, store_counters)$bytes_inline, 1)
})

# User codecs ------------------------------------------------------------------

lines_codec <- function() {
  codec(
    "lines",
    encode = function(value, path) writeLines(value, path, useBytes = TRUE),
    decode = function(path, meta) readLines(path, encoding = "UTF-8"),
    supports = function(value) is.character(value) && !anyNA(value)
  )
}

test_that("a user codec writes and reads through a file", {
  s <- local_stash(codecs = list(lines_codec()))
  stash_set(s, "k", c("a", "b"), codec = lines_codec())
  expect_identical(stash_get(s, "k"), c("a", "b"))
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
})

test_that("an entry by an unknown codec is refused on read, with the codec named", {
  dir <- withr::local_tempdir()
  s <- stash(dir, codecs = list(lines_codec()))
  stash_set(s, "k", "a", codec = lines_codec())
  stash_close(s)
  s2 <- stash(dir)
  withr::defer(stash_close(s2))
  cnd <- expect_error(stash_get(s2, "k"), class = "dastash_codec_error")
  expect_identical(cnd$codec, "lines")
})

test_that("a user default codec is needed to write but not to read", {
  dir <- withr::local_tempdir()
  s <- stash(dir, codec = lines_codec(), codecs = list(lines_codec()))
  stash_set(s, "k", "a")
  stash_close(s)
  s2 <- stash(dir, readonly = TRUE)
  expect_error(stash_get(s2, "k"), class = "dastash_codec_error")
  # A process cannot hold a directory read-only and writable at once.
  expect_error(stash(dir), class = "dastash_readonly")
  stash_close(s2)
  s3 <- stash(dir, codecs = list(lines_codec()))
  withr::defer(stash_close(s3))
  expect_identical(stash_get(s3, "k"), "a")
  s4 <- stash(dir)
  withr::defer(stash_close(s4))
  expect_error(stash_set(s4, "j", "b"), class = "dastash_codec_error")
  stash_set(s4, "j", 1, codec = codec_rds())
  expect_identical(stash_get(s4, "j"), 1)
})

# Processes --------------------------------------------------------------------

test_that("another process reads what this one wrote", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- stash(dir)
  withr::defer(stash_close(s))
  stash_set(s, "from-parent", list(n = 1:3))
  got <- callr::r(
    function(dir) {
      s <- dastash::stash(dir)
      on.exit(dastash::stash_close(s))
      dastash::stash_set(s, "from-child", "hello")
      dastash::stash_get(s, "from-parent")
    },
    args = list(dir = dir)
  )
  expect_identical(got, list(n = 1:3))
  expect_identical(stash_get(s, "from-child"), "hello")
})
