# Round trip through a codec, via a real file.
round_trip <- function(codec, value) {
  path <- withr::local_tempfile(.local_envir = parent.frame())
  info <- codec_encode(codec, value, path)
  codec_decode(codec, path, info$meta)
}

# Values codec_rds() must bring back identical.
rds_values <- list(
  NULL, 1L, c(1.5, NA, NaN, Inf), c(TRUE, NA), "x", c("a", NA, "é"),
  as.raw(0:255), 1i,
  factor(c("b", "a"), levels = c("a", "b", "z")),
  as.Date("2026-08-29"), as.POSIXct("2026-08-29 10:00:00.5", tz = "Europe/Zurich"),
  as.difftime(3, units = "hours"),
  structure(1:3, class = "my_class", extra = list(a = 1)),
  list(a = 1, b = list(c = "d")), list(),
  data.frame(x = 1:3, y = c("a", "b", NA), row.names = c("r1", "r2", "r3")),
  matrix(1:6, 2, dimnames = list(c("a", "b"), NULL))
)

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

test_that("codec_raw() refuses what it would not bring back", {
  for (v in list(c("a", "b"), NA_character_, c(a = "x"), structure(as.raw(1), class = "x"), 1L)) {
    expect_error(round_trip(codec_raw(), v), class = "dastash_type_error")
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
  expect_error(round_trip(codec_file(), tempfile()), class = "dastash_type_error")
  expect_error(round_trip(codec_file(), tempdir()), class = "dastash_type_error")
  expect_error(round_trip(codec_file(), 1), class = "dastash_type_error")
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
  expect_error(round_trip(lines, c("a", NA)), class = "dastash_type_error")

  registry <- codec_registry(list(lines))
  expect_identical(codec_lookup("lines", 1L, registry)$name, "lines")
  expect_identical(codec_lookup("rds", 1L)$name, "rds")
})

test_that("an unknown or newer codec cannot decode", {
  expect_error(codec_lookup("lines", 1L), class = "dastash_codec_error")
  expect_error(codec_lookup("rds", 2L), class = "dastash_codec_error")
})

test_that("codec() validates what it is given", {
  enc <- function(value, path) NULL
  dec <- function(path, meta) NULL
  expect_error(codec("rds", enc, dec), class = "dastash_codec_error")
  expect_error(codec("auto", enc, dec), class = "dastash_codec_error")
  expect_error(codec("has space", enc, dec), class = "dastash_codec_error")
  expect_error(codec("x", function(value) NULL, dec), class = "dastash_codec_error")
  expect_error(codec("x", enc, function(path) NULL), class = "dastash_codec_error")
  expect_error(codec("x", enc, dec, ext = ".txt"), class = "dastash_codec_error")
  expect_error(codec("x", enc, dec, version = 1.5), class = "dastash_codec_error")
  expect_error(codec("x", enc, dec, supports = TRUE), class = "dastash_codec_error")
  expect_error(codec("x", enc, dec, "extra"), class = "rlib_error_dots_nonempty")
  expect_error(codec_registry(list(codec_rds())), class = "dastash_codec_error")
  expect_error(codec_registry(list(1)), class = "dastash_codec_error")
})

test_that("an encoder or decoder that fails is dastash_codec_error, with the cause", {
  broken <- codec(
    "broken",
    encode = function(value, path) stop("disk on fire"),
    decode = function(path, meta) stop("cannot read")
  )
  path <- withr::local_tempfile()
  cnd <- expect_error(codec_encode(broken, 1, path), class = "dastash_codec_error")
  expect_match(conditionMessage(cnd$parent), "disk on fire")
  expect_error(codec_decode(broken, path, NULL), class = "dastash_codec_error")
})

test_that("codecs print what they are", {
  expect_output(print(codec_rds()), "<dastash_codec> rds v1 .rds", fixed = TRUE)
  expect_output(print(codec_file()), "always a file", fixed = TRUE)
  expect_output(print(codec_auto()), "auto")
})
