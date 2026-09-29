# The encoding is frozen: a failure here means a stored key would no longer be
# found. Fix the code, never the golden file (spec §0).

golden <- function() {
  utils::read.csv(
    test_path("golden", "key-vectors.csv"),
    colClasses = "character", encoding = "UTF-8", na.strings = character()
  )
}

test_that("every golden vector encodes, hashes and stores as recorded", {
  g <- golden()
  expect_gt(nrow(g), 100)
  for (i in seq_len(nrow(g))) {
    row <- g[i, ]
    if (grepl("bit64::", row$expr, fixed = TRUE)) skip_if_not_installed("bit64")
    value <- eval(parse(text = row$expr, encoding = "UTF-8"))
    text <- stash_key_chr(value)
    if (startsWith(row$canon, "<") && endsWith(row$canon, " bytes>")) {
      expect_identical(
        paste0("<", nchar(text, type = "bytes"), " bytes>"), row$canon,
        label = row$expr
      )
    } else {
      expect_identical(text, enc2utf8(row$canon), label = row$expr)
    }
    expect_identical(stash_key_hash(value), row$hash, label = row$expr)
    expect_identical(key_storage(text)$stored, enc2utf8(row$stored), label = row$expr)
  }
})

test_that("the key encoding version is 1", {
  expect_identical(KEY_ENCODING_VERSION, 1L)
})

# Properties -----------------------------------------------------------------

test_that("a key passes through stash_key() unchanged", {
  values <- list("a/b", "{x}", 1L, 0.1, list(b = 2, a = 1), NULL, as.Date("2026-08-29"))
  for (v in values) {
    k <- stash_key(v)
    expect_identical(stash_key(k), k)
    expect_identical(stash_key_chr(k), stash_key_chr(v))
  }
})

test_that("plain text is its own key", {
  for (s in c("XSWX/2026-08-29", "hello world", "a,b=c:d", "été", "Dog", "x:y", "")) {
    expect_identical(stash_key_chr(s), enc2utf8(s))
  }
})

test_that("text that starts like an encoded value is escaped", {
  for (s in c("~", "#", "{", "(", "D{", "s:", "i[", "e{", "t:x", "#abc")) {
    expect_true(startsWith(stash_key_chr(s), "s:"), label = s)
  }
  # A literal string can never look like a digested key.
  digest_like <- paste0("#", strrep("a", 64))
  expect_false(startsWith(stash_key_chr(digest_like), "#"))
})

test_that("equivalent values are one key", {
  expect_identical(stash_key_chr(1L), stash_key_chr(1))
  expect_identical(stash_key_chr(-0), stash_key_chr(0L))
  expect_identical(stash_key_chr(NA_integer_), stash_key_chr(NA_real_))
  expect_identical(stash_key_chr(c(1L, 2L)), stash_key_chr(c(1, 2)))
  expect_identical(
    stash_key_chr(as.POSIXct("2026-08-29 12:00:00", tz = "Europe/Zurich")),
    stash_key_chr(as.POSIXct("2026-08-29 10:00:00", tz = "UTC"))
  )
  expect_identical(
    stash_key_chr(as.difftime(1, units = "hours")),
    stash_key_chr(as.difftime(3600, units = "secs"))
  )
  expect_identical(
    stash_key_chr(factor("a", levels = c("a", "b"))),
    stash_key_chr(factor("a"))
  )
  expect_identical(stash_key(a = 1, b = 2), stash_key(b = 2, a = 1))
  expect_identical(stash_key_chr(list(b = 2, a = 1)), stash_key_chr(list(a = 1, b = 2)))
  expect_identical(stash_key_chr(data.frame(x = 1, y = 2)), stash_key_chr(data.frame(y = 2, x = 1)))
  skip_if_not_installed("bit64")
  expect_identical(stash_key_chr(bit64::as.integer64(7)), stash_key_chr(7L))
})

test_that("distinct values are distinct keys", {
  # A domain with no two equivalent members: injectivity means as many keys as
  # values.
  strings <- c("", "a", "A", "a,b", "a%2Cb", "a=b", "{a}", "~", "#", "!", "é", "é", "a\tb", "i:1")
  numbers <- c(0.5, -0.5, 0.1, 1 / 3, 1e-300, 5e-324, -5e-324, 2^53 + 2, Inf, -Inf, NaN)
  scalars <- c(
    as.list(strings), as.list(numbers),
    list(0L, 1L, -1L, NA_integer_, TRUE, FALSE, NA, as.raw(0), as.raw(1)),
    list(as.Date("2026-08-29"), as.POSIXct(0, tz = "UTC"), as.difftime(1.5, units = "secs")),
    list(factor("a"), NULL, NA_character_)
  )
  containers <- list(
    list(), list(NULL), list(list()), list(1L), list(1L, 2L), list(2L, 1L),
    list(a = 1L), list(b = 1L), list(a = 1L, b = 2L), list(a = 2L, b = 1L),
    c(a = 1L), c(a = 1L, b = 2L), c(b = 2L, a = 1L), 1:2, 2:1, integer(),
    character(), c("a", "b"), data.frame(a = 1:2), data.frame(a = 2:1), data.frame()
  )
  values <- c(scalars, containers)
  texts <- vapply(values, stash_key_chr, character(1))
  expect_identical(anyDuplicated(texts), 0L)
})

test_that("doubles encode exactly and independently of the C library", {
  expect_identical(stash_key_chr(0.1), "f:0x1.999999999999ap-4")
  expect_identical(stash_key_chr(5e-324), "f:0x0.0000000000001p-1022")
  expect_identical(stash_key_chr(.Machine$double.xmax), "f:0x1.fffffffffffffp+1023")
  expect_identical(stash_key_chr(-1.5), "f:-0x1.8p+0")
  # Exact: R's own parser, the same on every platform, reads each one back to
  # the identical double, subnormals included.
  set.seed(42)
  x <- c(
    runif(200, -1e6, 1e6), exp(rnorm(200, 0, 200)), -exp(rnorm(50, 0, 200)),
    runif(50) * 2^-1022, -runif(50) * 2^-1022
  )
  x <- x[is.finite(x) & x != trunc(x)]
  text <- vapply(x, hex_float, character(1))
  expect_identical(as.numeric(text), x)
  expect_true(all(grepl("^-?0x[01](\\.[0-9a-f]*[1-9a-f])?p[+-][0-9]+$", text)))
})

test_that("microseconds are kept and rounded", {
  t0 <- as.POSIXct("2026-08-29 10:00:00", tz = "UTC")
  expect_identical(stash_key_chr(t0 + 0.123456), "t:2026-08-29T10:00:00.123456Z")
  expect_identical(stash_key_chr(t0 + 0.9999996), "t:2026-08-29T10:00:01.000000Z")
})

# Errors ---------------------------------------------------------------------

test_that("values with no encoding are refused with a hint", {
  for (v in list(mean, globalenv(), quote(x), quote(f(x)), 1i, ~x)) {
    cnd <- expect_error(stash_key_chr(v), class = "dastash_key_invalid")
    expect_match(conditionMessage(cnd), "omit =")
  }
})

test_that("names are all or none", {
  expect_error(stash_key_chr(list(a = 1, 2)), class = "dastash_key_invalid")
  expect_error(stash_key_chr(c(a = 1, 2)), class = "dastash_key_invalid")
  expect_error(stash_key(a = 1, 2), class = "dastash_key_invalid")
  expect_error(stash_key_chr(stats::setNames(list(1, 2), c("a", NA))), class = "dastash_key_invalid")
})

test_that("a list cannot repeat a name", {
  expect_error(stash_key_chr(list(a = 1, a = 2)), class = "dastash_key_invalid")
})

test_that("infinite dates and times are refused", {
  expect_error(stash_key_chr(structure(Inf, class = "Date")), class = "dastash_key_invalid")
  expect_error(stash_key_chr(as.POSIXct(Inf, tz = "UTC")), class = "dastash_key_invalid")
})

test_that("strings that are not UTF-8 are refused", {
  bytes <- "caf\xe9"
  Encoding(bytes) <- "bytes"
  expect_error(stash_key_chr(bytes), class = "dastash_key_invalid")
})

test_that("latin1 strings are keyed by their UTF-8 text", {
  latin <- "caf\xe9"
  Encoding(latin) <- "latin1"
  expect_identical(stash_key_chr(latin), "café")
})

test_that("stash_key() needs a value, and keys do not nest", {
  expect_error(stash_key(), class = "dastash_key_invalid")
  expect_error(stash_key(a = stash_key("x")), class = "dastash_key_invalid")
})

# The key object ---------------------------------------------------------------

test_that("keys print, format and convert to their text", {
  k <- stash_key(exchange = "XSWX", date = as.Date("2026-08-29"))
  expect_s3_class(k, "dastash_key")
  expect_identical(format(k), "{date=d:2026-08-29,exchange=s:XSWX}")
  expect_identical(as.character(k), format(k))
  expect_output(print(k), "<dastash_key> {date=d:2026-08-29,exchange=s:XSWX}", fixed = TRUE)
})

test_that("stash_key() splices with !!!", {
  args <- list(date = as.Date("2026-08-29"), exchange = "XSWX")
  expect_identical(stash_key(!!!args), stash_key(exchange = "XSWX", date = as.Date("2026-08-29")))
})

# Storage form -----------------------------------------------------------------

test_that("short keys are stored as their text", {
  s <- key_storage(strrep("x", KEY_MAX))
  expect_identical(s$stored, strrep("x", KEY_MAX))
  expect_false(s$digested)
})

test_that("long keys are stored as a digest and keep their text", {
  text <- strrep("x", KEY_MAX + 1L)
  s <- key_storage(text)
  expect_true(s$digested)
  expect_identical(s$stored, paste0("#", stash_key_hash(text)))
  expect_identical(nchar(s$stored, type = "bytes"), 65L)
  expect_identical(s$key_text, text)
  expect_identical(s$key_bytes, KEY_MAX + 1L)
})

test_that("very long keys keep a preview that does not split a character", {
  text <- strrep("é", CANON_KEEP_MAX)
  s <- key_storage(text)
  expect_null(s$key_text)
  expect_lte(nchar(s$key_preview, type = "bytes"), KEY_PREVIEW_MAX)
  expect_true(validUTF8(s$key_preview))
  expect_identical(s$key_preview, strrep("é", KEY_PREVIEW_MAX / 2))
})

test_that("limits fit the smallest page size", {
  # 8 bytes of an ordered index prefix plus a key, and a tag, NUL and key,
  # must fit libmdbx's key limit at 4 KiB pages (2022 bytes; design.md §5.3).
  expect_lte(8L + KEY_MAX, 2022L)
  expect_lte(TAG_MAX + 1L + KEY_MAX, 2022L)
})

test_that("stash_key_text() turns every listed key back into its key", {
  s <- local_stash()
  keys <- list(
    "plain", "{literal", list(n = 1), 1L, as.Date("2026-08-29"),
    strrep("x", 1000), strrep("y", 5000)
  )
  for (i in seq_along(keys)) stash_set(s, keys[[i]], i)
  listed <- stash_keys(s)
  expect_length(listed, length(keys))
  values <- vapply(listed, function(k) stash_get(s, stash_key_text(k)), numeric(1))
  expect_setequal(values, seq_along(keys))
  expect_error(stash_key_text(NA_character_), class = "dastash_key_invalid")
  expect_error(stash_key_text(c("a", "b")), class = "dastash_key_invalid")
})
