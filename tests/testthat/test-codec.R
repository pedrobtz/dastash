test_that("codec_rds() round-trips any R value exactly", {
  for (v in rds_values) {
    expect_identical(round_trip(codec_rds(), v), v)
  }
  expect_identical(round_trip(codec_rds(compress = TRUE), rds_values[[16]]), rds_values[[16]])
})

test_that("codec_rds() brings a function back working", {
  # Its environment comes back as a copy, so identical() cannot hold.
  f <- round_trip(codec_rds(), function(x) x + 1)
  expect_identical(f(1), 2)
})

test_that("codec_raw() round-trips raw vectors and single strings", {
  expect_identical(round_trip(codec_raw(), as.raw(0:255)), as.raw(0:255))
  expect_identical(round_trip(codec_raw(), raw()), raw())
  expect_identical(round_trip(codec_raw(), "café 日本"), "café 日本")
  expect_identical(round_trip(codec_raw(), ""), "")
})

test_that("codec_raw() stores exactly the bytes", {
  path <- withr::local_tempfile()
  codec_encode(codec_raw(), "café", path)
  expect_identical(readBin(path, "raw", 100), charToRaw(enc2utf8("café")))
})

test_that("codec_raw() stores unmarked UTF-8 text as itself in a locale that cannot hold it", {
  utf8 <- "été"
  unmarked <- rawToChar(charToRaw(utf8))
  invalid <- "caf\xe9"
  withr::local_locale(c(LC_CTYPE = "C"))
  skip_if(l10n_info()$`UTF-8`, "the C locale is UTF-8 here")
  path <- withr::local_tempfile()
  codec_encode(codec_raw(), unmarked, path)
  expect_identical(readBin(path, "raw", 100), charToRaw(utf8))
  expect_identical(round_trip(codec_raw(), unmarked), utf8)
  # Through the cache, codec_auto() picks codec_raw() for it.
  s <- local_cache()
  cache_set(s, "k", unmarked)
  expect_identical(cache_get(s, "k"), utf8)
  # Bytes that are neither native text nor UTF-8 are not text: codec_raw()
  # refuses them and codec_auto() keeps them exactly with codec_rds().
  expect_error(round_trip(codec_raw(), invalid), class = "dazcache_type_error")
  cache_set(s, "bad", invalid)
  expect_identical(charToRaw(cache_get(s, "bad")), charToRaw(invalid))
})

test_that("codec_raw() refuses what it would not bring back", {
  for (v in list(c("a", "b"), NA_character_, c(a = "x"), structure(as.raw(1), class = "x"), 1L)) {
    expect_error(round_trip(codec_raw(), v), class = "dazcache_type_error")
  }
})

test_that("codec_file() stores a copy and decodes to its path", {
  src <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("a,b", "1,2"), src)
  path <- withr::local_tempfile()
  info <- codec_encode(codec_file(), src, path)
  expect_identical(info$ext, "csv")
  expect_identical(codec_decode(codec_file(), path, info$meta), path)
  expect_identical(readLines(path), c("a,b", "1,2"))
  expect_true(codec_file()$always_file)
})

test_that("codec_file() refuses what is not a file", {
  expect_error(round_trip(codec_file(), tempfile()), class = "dazcache_type_error")
  expect_error(round_trip(codec_file(), tempdir()), class = "dazcache_type_error")
  expect_error(round_trip(codec_file(), 1), class = "dazcache_type_error")
})

test_that("codec_auto() picks raw for raw and bare strings, rds for the rest", {
  auto <- codec_auto()
  expect_identical(codec_for_value(auto, as.raw(1:3))$name, "raw")
  expect_identical(codec_for_value(auto, "text")$name, "raw")
  for (v in list(c("a", "b"), NA_character_, c(a = "x"), 1, list(), factor("a"), NULL, data.frame(x = 1))) {
    expect_identical(codec_for_value(auto, v)$name, "rds")
  }
  expect_identical(codec_for_value(codec_rds(), "text")$name, "rds")
})

test_that("a user codec round-trips and is looked up by name", {
  lines <- codec(
    "lines",
    encode = function(value, path) writeLines(value, path, useBytes = TRUE),
    decode = function(path, meta) readLines(path, encoding = "UTF-8"),
    ext = "txt",
    supports = function(value) is.character(value) && !anyNA(value)
  )
  expect_identical(round_trip(lines, c("a", "b")), c("a", "b"))
  expect_error(round_trip(lines, c("a", NA)), class = "dazcache_type_error")

  registry <- codec_registry(list(lines))
  expect_identical(codec_lookup("lines", 1L, registry)$name, "lines")
  expect_identical(codec_lookup("rds", 1L)$name, "rds")
})

test_that("an unknown or newer codec cannot decode", {
  expect_error(codec_lookup("lines", 1L), class = "dazcache_codec_error")
  expect_error(codec_lookup("rds", 2L), class = "dazcache_codec_error")
})

test_that("codec() validates what it is given", {
  enc <- function(value, path) NULL
  dec <- function(path, meta) NULL
  expect_error(codec("rds", enc, dec), class = "dazcache_codec_error")
  expect_error(codec("auto", enc, dec), class = "dazcache_codec_error")
  expect_error(codec("has space", enc, dec), class = "dazcache_codec_error")
  expect_error(codec("x", function(value) NULL, dec), class = "dazcache_codec_error")
  expect_error(codec("x", enc, function(path) NULL), class = "dazcache_codec_error")
  expect_error(codec("x", enc, dec, ext = ".txt"), class = "dazcache_codec_error")
  expect_error(codec("x", enc, dec, version = 1.5), class = "dazcache_codec_error")
  expect_error(codec("x", enc, dec, supports = TRUE), class = "dazcache_codec_error")
  expect_error(codec("x", enc, dec, "extra"), class = "dazcache_type_error")
  expect_error(codec_registry(list(codec_rds())), class = "dazcache_codec_error")
  expect_error(codec_registry(list(1)), class = "dazcache_codec_error")
})

test_that("an encoder or decoder that fails is dazcache_codec_error, with the cause", {
  broken <- codec(
    "broken",
    encode = function(value, path) stop("disk on fire"),
    decode = function(path, meta) stop("cannot read")
  )
  path <- withr::local_tempfile()
  cnd <- expect_error(codec_encode(broken, 1, path), class = "dazcache_codec_error")
  expect_match(conditionMessage(cnd$parent), "disk on fire")
  expect_error(codec_decode(broken, path, NULL), class = "dazcache_codec_error")
})

test_that("codecs print what they are", {
  expect_output(print(codec_rds()), "<dazcache_codec> rds v1 .rds", fixed = TRUE)
  expect_output(print(codec_file()), "always a file", fixed = TRUE)
  expect_output(print(codec_auto()), "auto")
})

test_that("codec_rds() refuses a value serialize() cannot keep alive", {
  s <- local_cache()
  path <- withr::local_tempfile()
  con <- file(path, "w")
  withr::defer(close(con))
  expect_false(codec_rds()$supports(con))
  expect_error(cache_set(s, "con", con), class = "dazcache_type_error")
  expect_error(cache_set(s, "con", con, codec = codec_rds()), class = "dazcache_type_error")
  ptr <- methods::new("externalptr")
  expect_false(codec_rds()$supports(ptr))
  expect_error(cache_set(s, "ptr", ptr), class = "dazcache_type_error")
  expect_false(cache_has(s, "con") || cache_has(s, "ptr"))
  expect_true(codec_rds()$supports(list(1, "a")))
})

test_that("an encode() that returns its value stores no meta", {
  csv <- codec(
    "csv",
    encode = function(value, path) {
      utils::write.csv(value, path, row.names = FALSE)
      invisible(value)
    },
    decode = function(path, meta) utils::read.csv(path),
    ext = "csv"
  )
  s <- local_cache(codecs = csv)
  df <- data.frame(x = 1:3, y = c("a", "b", "c"))
  cache_set(s, "df", df, codec = csv)
  record <- engine_read(s$engine, function(txn) store_get_record(s, txn, "df"))
  expect_null(record$codec_meta)
  expect_equal(cache_get(s, "df"), df)
})

test_that("meta is limited in size, and its ext must be letters and digits", {
  big <- codec(
    "big",
    encode = function(value, path) {
      writeLines(value, path)
      list(padding = strrep("x", 10000))
    },
    decode = function(path, meta) readLines(path)
  )
  bad_ext <- codec(
    "badext",
    encode = function(value, path) {
      writeLines(value, path)
      list(ext = "../x")
    },
    decode = function(path, meta) readLines(path)
  )
  s <- local_cache()
  expect_error(cache_set(s, "a", "v", codec = big), class = "dazcache_codec_error")
  expect_error(cache_set(s, "a", "v", codec = bad_ext), class = "dazcache_codec_error")
  expect_false(cache_has(s, "a"))
  expect_length(list.files(file.path(s$dir, "tmp")), 0L)
})

test_that("a codec that writes no file is a dazcache_codec_error", {
  none <- codec("none", encode = function(value, path) NULL, decode = function(path, meta) NULL)
  s <- local_cache()
  expect_error(cache_set(s, "z", 1, codec = none), class = "dazcache_codec_error")
  expect_false(cache_has(s, "z"))
})

test_that("codec_rds(compress = TRUE) round-trips inline and as a file", {
  s <- local_cache(inline_max = 1000)
  gz <- codec_rds(compress = TRUE)
  cache_set(s, "small", 1:10, codec = gz)
  large <- runif(2000)
  cache_set(s, "large", large, codec = gz)
  expect_true(cache_info(s, "small")$inline)
  expect_false(cache_info(s, "large")$inline)
  expect_identical(cache_get(s, "small"), 1:10)
  expect_identical(cache_get(s, "large"), large)
})

test_that("a second, different codec under a known name is refused (#120)", {
  s <- local_cache()
  c1 <- codec("lines", encode = function(v, p) writeLines(v, p), decode = function(p, m) readLines(p))
  c2 <- codec("lines", encode = function(v, p) writeLines(rev(v), p), decode = function(p, m) rev(readLines(p)))
  cache_set(s, "k1", c("1", "2"), codec = c1)
  expect_error(cache_set(s, "k2", c("1", "2"), codec = c2), class = "dazcache_codec_error")
  expect_false(cache_has(s, "k2"))
  # The same code built again is the same codec.
  again <- codec("lines", encode = function(v, p) writeLines(v, p), decode = function(p, m) readLines(p))
  cache_set(s, "k3", c("3", "4"), codec = again)
  expect_identical(cache_get(s, "k3"), c("3", "4"))
  t <- local_cache(codecs = list(c1))
  expect_error(cache_set(t, "k", "x", codec = c2), class = "dazcache_codec_error")
})

test_that("a cache keeps its codec's parameters when reopened (#120)", {
  dir <- withr::local_tempdir()
  s <- cache(dir, codec = codec_rds(compress = TRUE))
  cache_close(s)
  s <- cache(dir)
  withr::defer(cache_close(s))
  cache_set(s, "big", rep(1, 1e4))
  expect_lt(cache_entries(s)$bytes, 1000)
  expect_identical(cache_get(s, "big"), rep(1, 1e4))
  cache_close(s)
  expect_error(cache(dir, codec = codec_rds()), class = "dazcache_config_conflict")
  s <- cache(dir, codec = codec_rds(compress = TRUE))
})

test_that("only a meta element named exactly `ext` sets a blob's extension (#118)", {
  s <- local_cache(inline_max = 0)
  extra <- codec(
    "extra",
    encode = function(value, path) {
      writeLines(value, path)
      list(extra = "zzz")
    },
    decode = function(path, meta) readLines(path)
  )
  cache_set(s, "m", "hello", codec = extra)
  expect_identical(tools::file_ext(cache_path(s, "m")), "")
  expect_identical(cache_get(s, "m"), "hello")
  own <- codec(
    "own",
    encode = function(value, path) {
      writeLines(value, path)
      list(ext = "csv")
    },
    decode = function(path, meta) readLines(path),
    ext = "txt"
  )
  cache_set(s, "o", "hello", codec = own)
  expect_identical(tools::file_ext(cache_path(s, "o")), "csv")
})

test_that("a codec that writes a directory or a link is a codec error and leaves nothing staged (#119)", {
  s <- local_cache(inline_max = 0)
  dir_codec <- codec(
    "d",
    encode = function(value, path) {
      dir.create(path)
      writeLines("x", file.path(path, "f"))
      Sys.chmod(path, "0555")
    },
    decode = function(path, meta) path
  )
  expect_error(cache_set(s, "k", 1, codec = dir_codec), "a directory", class = "dazcache_codec_error")
  skip_on_os("windows")
  link_codec <- codec(
    "l",
    encode = function(value, path) file.symlink(withr::local_tempfile(), path),
    decode = function(path, meta) path
  )
  expect_error(cache_set(s, "l", 1, codec = link_codec), "a symbolic link", class = "dazcache_codec_error")
  expect_identical(list.files(file.path(s$dir, "tmp"), all.files = TRUE, no.. = TRUE), character())
  expect_identical(cache_count(s), 0L)
})

test_that("a decoder that returns its path needs always_file, and is refused without it (#121)", {
  s <- local_cache()
  bare <- codec("p", encode = function(value, path) writeLines(value, path), decode = function(path, meta) path)
  cache_set(s, "a", "x", codec = bare)
  expect_error(cache_get(s, "a"), "always_file", class = "dazcache_codec_error")
  filed <- codec(
    "pf",
    encode = function(value, path) writeLines(value, path),
    decode = function(path, meta) path,
    always_file = TRUE
  )
  cache_set(s, "b", "x", codec = filed)
  expect_identical(readLines(cache_get(s, "b")), "x")
  expect_error(codec("q", identity, identity, always_file = NA), class = "dazcache_codec_error")
})
