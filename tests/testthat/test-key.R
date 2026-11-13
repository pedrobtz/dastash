# The encoding is frozen: a failure here means a stored key would no longer be
# found. Fix the code, never the golden file (spec §0).

test_that("every golden vector encodes, hashes and stores as recorded", {
  expect_golden_vectors()
})

test_that("every golden vector holds in a hostile session (#67)", {
  withr::local_options(OutDec = ",", scipen = -5, digits = 3, warn = 2)
  withr::local_collate("C")
  withr::local_timezone("Pacific/Chatham")
  expect_golden_vectors()
})

test_that("every golden vector holds in a C-locale session (#67)", {
  skip_unless_children_see_this_build()
  skip_on_os("windows")
  golden_file <- test_path("golden", "key-vectors.csv")
  got <- callr::r(
    function(golden_file) {
      options(OutDec = ",", scipen = -5, digits = 3)
      g <- utils::read.csv(golden_file, colClasses = "character", encoding = "UTF-8", na.strings = character())
      bad <- character()
      for (i in seq_len(nrow(g))) {
        row <- g[i, ]
        if (grepl("bit64::", row$expr, fixed = TRUE) && !requireNamespace("bit64", quietly = TRUE)) next
        value <- eval(parse(text = row$expr, encoding = "UTF-8"))
        # Names whose bytes this locale rereads are not the row's value.
        nms <- names(value)
        if (!is.null(nms) && any(Encoding(nms) == "unknown" & grepl("[^ -~]", nms, useBytes = TRUE))) next
        text <- dazcache::cache_key_chr(value)
        ok <- if (startsWith(row$canon, "<")) {
          identical(paste0("<", nchar(text, type = "bytes"), " bytes>"), row$canon)
        } else {
          identical(charToRaw(text), charToRaw(enc2utf8(row$canon)))
        }
        if (!ok || !identical(dazcache::cache_key_hash(value), row$hash)) bad <- c(bad, row$expr)
      }
      list(locale = Sys.getlocale("LC_CTYPE"), n = nrow(g), bad = bad)
    },
    args = list(golden_file = normalizePath(golden_file)),
    env = c(callr::rcmd_safe_env(), LC_ALL = "C", LANG = "C", TZ = "Asia/Kathmandu")
  )
  expect_identical(got$locale, "C")
  expect_gt(got$n, 100)
  expect_identical(got$bad, character())
})

test_that("the key encoding version is 1", {
  expect_identical(KEY_ENCODING_VERSION, 1L)
})

# Properties -----------------------------------------------------------------

test_that("a key passes through cache_key() unchanged", {
  values <- list("a/b", "{x}", 1L, 0.1, list(b = 2, a = 1), NULL, as.Date("2026-08-29"))
  for (v in values) {
    k <- cache_key(v)
    expect_identical(cache_key(k), k)
    expect_identical(cache_key_chr(k), cache_key_chr(v))
  }
})

test_that("plain text is its own key", {
  for (s in c("XSWX/2026-08-29", "hello world", "a,b=c:d", "été", "Dog", "x:y", "")) {
    expect_identical(cache_key_chr(s), enc2utf8(s))
  }
})

test_that("text that starts like an encoded value is escaped", {
  for (s in c("~", "#", "{", "(", "D{", "s:", "i[", "e{", "t:x", "#abc")) {
    expect_true(startsWith(cache_key_chr(s), "s:"), label = s)
  }
  # A literal string can never look like a digested key.
  digest_like <- paste0("#", strrep("a", 64))
  expect_false(startsWith(cache_key_chr(digest_like), "#"))
})

test_that("equivalent values are one key", {
  expect_identical(cache_key_chr(1L), cache_key_chr(1))
  expect_identical(cache_key_chr(-0), cache_key_chr(0L))
  expect_identical(cache_key_chr(NA_integer_), cache_key_chr(NA_real_))
  expect_identical(cache_key_chr(c(1L, 2L)), cache_key_chr(c(1, 2)))
  expect_identical(
    cache_key_chr(as.POSIXct("2026-08-29 12:00:00", tz = "Europe/Zurich")),
    cache_key_chr(as.POSIXct("2026-08-29 10:00:00", tz = "UTC"))
  )
  expect_identical(
    cache_key_chr(as.difftime(1, units = "hours")),
    cache_key_chr(as.difftime(3600, units = "secs"))
  )
  expect_identical(
    cache_key_chr(factor("a", levels = c("a", "b"))),
    cache_key_chr(factor("a"))
  )
  expect_identical(cache_key(a = 1, b = 2), cache_key(b = 2, a = 1))
  expect_identical(cache_key_chr(list(b = 2, a = 1)), cache_key_chr(list(a = 1, b = 2)))
  expect_identical(cache_key_chr(data.frame(x = 1, y = 2)), cache_key_chr(data.frame(y = 2, x = 1)))
  skip_if_not_installed("bit64")
  expect_identical(cache_key_chr(bit64::as.integer64(7)), cache_key_chr(7L))
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
  texts <- vapply(values, cache_key_chr, character(1))
  expect_identical(anyDuplicated(texts), 0L)
})

test_that("doubles encode exactly and independently of the C library", {
  expect_identical(cache_key_chr(0.1), "f:0x1.999999999999ap-4")
  expect_identical(cache_key_chr(5e-324), "f:0x0.0000000000001p-1022")
  expect_identical(cache_key_chr(.Machine$double.xmax), "f:0x1.fffffffffffffp+1023")
  expect_identical(cache_key_chr(-1.5), "f:-0x1.8p+0")
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
  expect_identical(cache_key_chr(t0 + 0.123456), "t:2026-08-29T10:00:00.123456Z")
  expect_identical(cache_key_chr(t0 + 0.9999996), "t:2026-08-29T10:00:01.000000Z")
})

test_that("dates and times in years 0000 to 9999 agree with POSIXlt", {
  # The encoding computes the calendar itself; POSIXlt's fields are an
  # independent reference. The year is padded here because strftime("%Y")
  # pads it on macOS and not on glibc.
  civil <- function(lt) {
    sprintf("%04d-%02d-%02d", lt$year + 1900L, lt$mon + 1L, lt$mday)
  }
  set.seed(101)
  days <- c(round(stats::runif(2000, -719528, 2932896)), -719528, 2932896, 0, -1, 59, 60)
  expect_identical(
    unname(vapply(days, function(d) cache_key_chr(structure(d, class = "Date")), "")),
    paste0("d:", civil(as.POSIXlt(structure(days, class = "Date"))))
  )
  secs <- round(stats::runif(2000, -62167219200, 253402300799))
  lt <- as.POSIXlt(.POSIXct(secs, tz = "UTC"))
  expect_identical(
    unname(vapply(secs, function(s) cache_key_chr(.POSIXct(s, tz = "UTC")), "")),
    paste0(
      "t:", civil(lt), "T",
      sprintf("%02d:%02d:%02d", lt$hour, lt$min, as.integer(lt$sec)), ".000000Z"
    )
  )
})

test_that("dates and times outside years 0000 to 9999 keep distinct keys", {
  far <- structure(c(1e12, -4e15, 1e12 + 1), class = "Date")
  expect_identical(anyDuplicated(vapply(seq_along(far), function(i) cache_key_chr(far[i]), "")), 0L)
  s <- local_cache()
  cache_set(s, far[1], "first")
  expect_identical(cache_get(s, far[2], default = "miss"), "miss")
})

# Errors ---------------------------------------------------------------------

test_that("values with no encoding are refused with a hint", {
  for (v in list(mean, globalenv(), quote(x), quote(f(x)), 1i, ~x)) {
    cnd <- expect_error(cache_key_chr(v), class = "dazcache_key_invalid")
    expect_match(conditionMessage(cnd), "omit =")
  }
})

test_that("names are all or none", {
  expect_error(cache_key_chr(list(a = 1, 2)), class = "dazcache_key_invalid")
  expect_error(cache_key_chr(c(a = 1, 2)), class = "dazcache_key_invalid")
  expect_error(cache_key(a = 1, 2), class = "dazcache_key_invalid")
  expect_error(cache_key_chr(stats::setNames(list(1, 2), c("a", NA))), class = "dazcache_key_invalid")
})

test_that("a list cannot repeat a name", {
  expect_error(cache_key_chr(list(a = 1, a = 2)), class = "dazcache_key_invalid")
})

test_that("infinite dates and times are refused", {
  expect_error(cache_key_chr(structure(Inf, class = "Date")), class = "dazcache_key_invalid")
  expect_error(cache_key_chr(as.POSIXct(Inf, tz = "UTC")), class = "dazcache_key_invalid")
})

test_that("dates and times beyond 2^52 days or seconds of 1970 are refused", {
  expect_identical(cache_key_chr(structure(2^52, class = "Date")), "d:12330436978418-07-07")
  expect_error(cache_key_chr(structure(2^52 + 1, class = "Date")), class = "dazcache_key_invalid")
  expect_error(cache_key_chr(structure(-2^53, class = "Date")), class = "dazcache_key_invalid")
  expect_error(cache_key_chr(.POSIXct(1e17, tz = "UTC")), class = "dazcache_key_invalid")
  expect_error(cache_key_chr(.POSIXct(-2^52 - 1, tz = "UTC")), class = "dazcache_key_invalid")
})

test_that("strings that are not UTF-8 are refused", {
  bytes <- "caf\xe9"
  Encoding(bytes) <- "bytes"
  expect_error(cache_key_chr(bytes), class = "dazcache_key_invalid")
  # Unmarked, in a UTF-8 session, the same bytes are invalid native text.
  skip_if_not(l10n_info()$`UTF-8`)
  native <- "caf\xe9"
  expect_identical(Encoding(native), "unknown")
  expect_error(cache_key_chr(native), class = "dazcache_key_invalid")
})

test_that("unmarked UTF-8 text keys the same in a session whose locale cannot hold it", {
  utf8 <- "été"
  unmarked <- rawToChar(charToRaw(utf8))
  expect_identical(Encoding(unmarked), "unknown")
  named <- TRUE
  names(named) <- unmarked
  withr::local_locale(c(LC_CTYPE = "C"))
  skip_if(l10n_info()$`UTF-8`, "the C locale is UTF-8 here")
  expect_identical(cache_key_chr(unmarked), utf8)
  expect_identical(cache_key_chr(named), paste0("l{", utf8, "=T}"))
  expect_identical(cache_key_chr(list(x = unmarked)), cache_key_chr(list(x = utf8)))
  # Never the text R prints for bytes it cannot show, which is another key.
  shown <- c(`<c3><a9>t<c3><a9>` = TRUE)
  expect_false(identical(cache_key_chr(named), cache_key_chr(shown)))
  # Bytes that are neither native text nor UTF-8 are still refused.
  expect_error(cache_key_chr("caf\xe9"), class = "dazcache_key_invalid")
})

test_that("an S4 object cannot be a key", {
  setClass("DazcacheTestKey", representation(x = "numeric"), where = environment())
  expect_error(cache_key_chr(methods::new("DazcacheTestKey", x = 1)), class = "dazcache_key_invalid")
})

test_that("latin1 strings are keyed by their UTF-8 text", {
  latin <- "caf\xe9"
  Encoding(latin) <- "latin1"
  expect_identical(cache_key_chr(latin), "café")
})

test_that("cache_key() needs a value, and keys do not nest", {
  expect_error(cache_key(), class = "dazcache_key_invalid")
  expect_error(cache_key(a = cache_key("x")), class = "dazcache_key_invalid")
})

# The key object ---------------------------------------------------------------

test_that("keys print, format and convert to their text", {
  k <- cache_key(exchange = "XSWX", date = as.Date("2026-08-29"))
  expect_s3_class(k, "dazcache_key")
  expect_identical(format(k), "{date=d:2026-08-29,exchange=s:XSWX}")
  expect_identical(as.character(k), format(k))
  expect_output(print(k), "<dazcache_key> {date=d:2026-08-29,exchange=s:XSWX}", fixed = TRUE)
})

test_that("cache_key() splices with !!!", {
  args <- list(date = as.Date("2026-08-29"), exchange = "XSWX")
  expect_identical(cache_key(!!!args), cache_key(exchange = "XSWX", date = as.Date("2026-08-29")))
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
  expect_identical(s$stored, paste0("#", cache_key_hash(text)))
  expect_identical(nchar(s$stored, type = "bytes"), 65L)
  expect_identical(s$key_text, text)
  expect_identical(s$key_bytes, KEY_MAX + 1L)
})

test_that("very long keys keep a preview that does not split a character", {
  # One ASCII byte first, so the preview's last byte falls inside an "é".
  text <- paste0("x", strrep("é", CANON_KEEP_MAX))
  s <- key_storage(text)
  expect_null(s$key_text)
  expect_identical(nchar(s$key_preview, type = "bytes"), KEY_PREVIEW_MAX - 1L)
  expect_true(validUTF8(s$key_preview))
  expect_identical(s$key_preview, paste0("x", strrep("é", (KEY_PREVIEW_MAX - 2L) / 2L)))
})

test_that("limits fit the smallest page size", {
  # 8 bytes of an ordered index prefix plus a key, and a tag, NUL and key,
  # must fit libmdbx's key limit at 4 KiB pages (design.md §5.3), as this
  # build of libmdbx reports it.
  limit <- mdbx::mdbx_limits(4096)$keysize_max
  expect_lte(8L + KEY_MAX, limit)
  expect_lte(TAG_MAX + 1L + KEY_MAX, limit)
})

test_that("cache_key_text() turns every listed key back into its key", {
  s <- local_cache()
  keys <- list(
    "plain", "{literal", list(n = 1), 1L, as.Date("2026-08-29"),
    strrep("x", 1000), strrep("y", 5000)
  )
  for (i in seq_along(keys)) cache_set(s, keys[[i]], i)
  listed <- cache_keys(s)
  expect_length(listed, length(keys))
  values <- vapply(listed, function(k) cache_get(s, cache_key_text(k)), numeric(1))
  expect_setequal(values, seq_along(keys))
  expect_error(cache_key_text(NA_character_), class = "dazcache_key_invalid")
  expect_error(cache_key_text(c("a", "b")), class = "dazcache_key_invalid")
})

test_that("a key's class and attributes are not part of it, digested or not (#105)", {
  s <- local_cache()
  for (n in c(10L, 600L, 5000L)) {
    long <- strrep("k", n)
    g <- structure(long, note = "x", class = c("glue", "character"))
    expect_identical(cache_key(g), cache_key(long))
    expect_null(attributes(cache_key_chr(g)))
    expect_null(attributes(cache_key(g)$text))
    cache_set(s, g, "G")
    expect_identical(cache_get(s, long, default = "MISS"), "G")
    expect_false(cache_add(s, long, "second"))
    expect_identical(cache_get(s, g), "G")
  }
  expect_null(attributes(cache_key_text(structure("ab", class = "glue"))$text))
})

test_that("malformed and exotic classed values key or are refused, never another error (#106)", {
  deep <- list(1)
  for (i in 1:3000) deep <- list(deep)
  refused <- list(
    structure(5L, class = "factor", levels = c("a", "b")),
    structure(1L, class = "factor"),
    structure(1, class = "difftime"),
    structure(1, class = "difftime", units = "fortnights"),
    structure(c("x", "y"), class = c("POSIXct", "POSIXt")),
    structure(c("2026-01-01", "x"), class = "Date"),
    structure(list(a = 1:2, b = 1), class = "data.frame"),
    deep
  )
  for (x in refused) {
    expect_error(cache_key_chr(x), class = "dazcache_key_invalid")
  }
  expect_identical(cache_key_chr(numeric_version("1.2")), "(i[1,2])")
  expect_identical(cache_key_chr(package_version("1.2.3")), "(i[1,2,3])")
  expect_identical(cache_key_chr(structure(list(), class = "data.frame")), "D{}")
  expect_identical(cache_key_chr(structure(list(1, "a"), class = "foo")), "(i:1,s:a)")
  s <- local_cache()
  cache_set(s, getRversion(), 1)
  expect_identical(cache_get(s, getRversion()), 1)
})

test_that("a non-ASCII prefix matches the same keys in a C locale (#107)", {
  skip_unless_children_see_this_build()
  skip_on_os("windows")
  dir <- withr::local_tempdir()
  got <- callr::r(
    function(dir) {
      u <- rawToChar(as.raw(c(0x63, 0x61, 0x66, 0xc3, 0xa9)))
      s <- dazcache::cache(dir)
      dazcache::cache_set(s, u, 1)
      dazcache::cache_set(s, paste0(u, "/x"), 2)
      dazcache::cache_set(s, "other", 3)
      keys <- length(dazcache::cache_keys(s, prefix = u))
      entries <- nrow(dazcache::cache_entries(s, prefix = u))
      a <- dazcache::as_cachem(s, prefix = paste0(u, "/"))
      size <- a$size()
      dazcache::cache_evict(s, prefix = u)
      left <- dazcache::cache_count(s)
      dazcache::cache_close(s)
      c(keys, entries, size, left)
    },
    args = list(dir = dir),
    env = c(callr::rcmd_safe_env(), LC_ALL = "C", LANG = "C")
  )
  expect_identical(got, c(2L, 2L, 1L, 1L))
})

test_that("a whole double at ±2^53 keys as the integer64 of the same value (#92)", {
  skip_if_not_installed("bit64")
  for (x in c(2^53, -2^53, 2^53 - 1, -(2^53 - 1), 0, 1)) {
    big <- bit64::as.integer64(x)
    expect_identical(cache_key_chr(x), cache_key_chr(big), label = format(x, digits = 17))
    expect_identical(cache_key_chr(x), paste0("i:", sprintf("%.0f", x)))
  }
  expect_false(identical(cache_key_chr(2^53 + 2), cache_key_chr(bit64::as.integer64(2^53 + 2))))
})

# A key shared by two different values returns one's value for the other: the
# one failure a cache cannot tolerate. #101 was one (far dates all keyed as
# `d:NA`). Values are drawn from the whole grammar, avoiding the pairs the spec
# makes equal (`1L` and `1`, `-0` and `0`, ignored attributes), so any two that
# differ must key differently (#133).
test_that("different values never share a key", {
  set.seed(133)
  pick <- function(x, n = 1) x[sample.int(length(x), n, replace = TRUE)]
  specials <- c("", "a", "b", ",", "=", "[", "]", "{", "}", "(", ")", ":", "!", "~", "%",
    "%2C", "#", "\\", "\n", "\t", "é", "é", "中", "s:a", "i:1", "D{", "~x")
  text <- function(n) {
    vapply(seq_len(n), function(i) paste(pick(specials, sample.int(3, 1)), collapse = ""), "")
  }
  doubles <- c(0, 1, -1, 2^53, -2^53, 2^53 + 2, 0.1, 1 / 3, -1.5, 1e300, 5e-324, NaN, NA, Inf, -Inf)
  days <- c(0, -1, 59, 60, -719528, 2932896, 2932897, -719529, 1e12, -4e15, 2^52)
  secs <- c(0, -1, 0.5, 1e-6, -1e-6, 86399.999999, 253402300800, 1e15, -1e15)
  atom <- function() {
    n <- pick(c(1L, 1L, 2L, 3L))
    switch(
      pick(c("s", "f", "l", "r", "d", "t", "e", "u")),
      s = text(n),
      f = pick(doubles, n),
      l = pick(c(TRUE, FALSE, NA), n),
      r = as.raw(sample.int(256, n, replace = TRUE) - 1L),
      d = structure(pick(days, n), class = "Date"),
      t = .POSIXct(pick(secs, n), tz = "UTC"),
      e = factor(text(n)),
      u = as.difftime(pick(doubles[is.finite(doubles)], n), units = "secs")
    )
  }
  named <- function(x) {
    if (length(x) > 0L && runif(1) < 0.3) {
      nms <- make.unique(text(length(x)))
      nms[!nzchar(nms)] <- "z"
      names(x) <- make.unique(nms)
    }
    x
  }
  value <- function(depth = 0L) {
    r <- runif(1)
    if (depth >= 3L || r < 0.55) return(named(atom()))
    if (r < 0.62) return(NULL)
    if (r < 0.70) {
      cols <- sample.int(3, 1)
      rows <- sample.int(3, 1)
      df <- lapply(seq_len(cols), function(j) pick(doubles, rows))
      names(df) <- make.unique(paste0("c", text(cols)))
      return(as.data.frame(df, optional = TRUE))
    }
    named(lapply(seq_len(sample.int(3, 1) - 1L), function(i) value(depth + 1L)))
  }
  values <- lapply(seq_len(3000), function(i) value())
  # A dense family where an escape that fails collides at once: vectors and
  # lists of a few separator-laden strings, `c("a,", "a")` beside `c("a", ",a")`.
  tight <- c("a", ",", "a,", ",a", "=", "a=", "(", ")", "[", "]", ":")
  dense <- lapply(seq_len(1500), function(i) {
    x <- pick(tight, sample.int(3, 1))
    switch(pick(c("v", "l", "n")), v = x, l = as.list(x), n = list(x, pick(tight)))
  })
  values <- c(values, dense)
  values <- values[!duplicated(values)]
  keys <- vapply(values, cache_key_chr, "")
  dup <- which(duplicated(keys))
  if (length(dup) > 0L) {
    first <- match(keys[dup[[1L]]], keys)
    fail(paste(
      "Two different values share a key:",
      paste(deparse(values[[first]]), collapse = ""),
      paste(deparse(values[[dup[[1L]]]]), collapse = ""),
      keys[[first]],
      sep = "\n"
    ))
  }
  expect_gt(length(values), 2200)
  # And the pairs the spec makes equal do share one.
  expect_identical(cache_key_chr(1L), cache_key_chr(1))
  expect_identical(cache_key_chr(list(-0)), cache_key_chr(list(0)))
  expect_identical(cache_key_chr(matrix(1:4, 2)), cache_key_chr(1:4))
  expect_identical(cache_key_chr(factor("a", levels = c("a", "b"))), cache_key_chr(factor("a")))
  expect_identical(
    cache_key_chr(.POSIXct(0, tz = "UTC")),
    cache_key_chr(.POSIXct(0, tz = "America/New_York"))
  )
  expect_identical(cache_key_chr(as.difftime(1, units = "mins")), cache_key_chr(as.difftime(60, units = "secs")))
})
