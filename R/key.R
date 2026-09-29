# The canonical key encoding: design.md §5 and inst/spec/key-encoding-v1.md.
#
# Identity comes from this text, never from serialize(), so it must not change
# once a store exists. Every rule here is frozen by the golden vectors in
# tests/testthat/golden/key-vectors.csv; a change to any of them is a new
# KEY_ENCODING_VERSION, not an edit.

KEY_ENCODING_VERSION <- 1L

# Stored-key limits in bytes. Constants, not derived from the page size, so a
# store written on one machine opens on another (design.md §5.3).
KEY_MAX <- 512L
TAG_MAX <- 256L
CANON_KEEP_MAX <- 4096L
KEY_PREVIEW_MAX <- 256L

#' Keys
#'
#' @description
#' Every function that takes a `key` accepts a string, a `dastash_key`, or any
#' value the canonical encoding covers. `stash_key()` builds a key from values;
#' `stash_key_chr()` returns the canonical text a key is stored under, and
#' `stash_key_hash()` its SHA-256.
#'
#' A single string is its own text: `"XSWX/2026-08-29"` is stored under exactly
#' those bytes. Anything else — numbers, dates, vectors, lists, data frames, or
#' several values — is written in a specified text encoding in which field order
#' does not matter, `1L` and `1` agree, and a timestamp's time zone is not part
#' of its identity. A string that begins like an encoded value (`{`, `(`, `~`,
#' `#`, `D{`, or a type tag such as `s:`) is escaped so the two can never
#' collide.
#'
#' Functions, environments, connections, S4 objects and external pointers have
#' no encoding and raise `dastash_key_invalid`.
#'
#' @param ... Values that make up the key: one unnamed value, or several values
#'   that are either all named or all unnamed. Named values are ordered by name,
#'   so their order does not matter. Supports `!!!` to splice a list.
#' @param key A string, a `dastash_key`, or a value the encoding covers.
#'
#' @return `stash_key()` returns a `dastash_key`. `stash_key_chr()` returns the
#'   canonical text as a string, and `stash_key_hash()` the SHA-256 of that text
#'   as 64 lower-case hex characters.
#'
#' @examples
#' stash_key("XSWX/2026-08-29")
#'
#' k <- stash_key(exchange = "XSWX", date = as.Date("2026-08-29"))
#' k
#' identical(k, stash_key(date = as.Date("2026-08-29"), exchange = "XSWX"))
#'
#' stash_key_chr(list(n = 1L, p = 0.1))
#' stash_key_hash("XSWX/2026-08-29")
#' @export
stash_key <- function(...) {
  values <- rlang::list2(...)
  if (length(values) == 0L) {
    abort_key_invalid("A key needs at least one value.")
  }
  nms <- names(values)
  if (length(values) == 1L && (is.null(nms) || !nzchar(nms))) {
    return(as_dastash_key(values[[1L]]))
  }
  new_dastash_key(key_canon(values))
}

#' @rdname stash_key
#' @export
stash_key_chr <- function(key) {
  key_canon(key)
}

#' @rdname stash_key
#' @export
stash_key_hash <- function(key) {
  hash_text(key_canon(key))
}

new_dastash_key <- function(text) {
  structure(list(text = text), class = "dastash_key")
}

as_dastash_key <- function(x) {
  if (inherits(x, "dastash_key")) x else new_dastash_key(key_canon(x))
}

is_dastash_key <- function(x) inherits(x, "dastash_key")

#' @export
format.dastash_key <- function(x, ...) {
  x$text
}

#' @export
as.character.dastash_key <- function(x, ...) {
  x$text
}

#' @export
print.dastash_key <- function(x, ...) {
  cat("<dastash_key> ", x$text, "\n", sep = "")
  invisible(x)
}

# The canonical text of any key: a dastash_key carries it; a plain string is
# itself unless it starts with an opener; anything else is a value.
key_canon <- function(x, call = rlang::caller_env()) {
  if (is_dastash_key(x)) {
    return(x$text)
  }
  if (is_plain_string(x)) {
    text <- utf8_text(x, call = call)
    if (!starts_with_opener(text)) {
      return(text)
    }
  }
  canon_value(x, call = call)
}

# A character(1), not NA, with no names. Other attributes are ignored, as they
# are everywhere in the encoding (spec §4).
is_plain_string <- function(x) {
  is.character(x) && length(x) == 1L && !is.na(x) && is.null(names(x)) && !isS4(x)
}

# Text at the top level that could be mistaken for an encoded value: `~`, `#`,
# `{`, `(`, `D{`, or a type tag followed by `:`, `[` or `{`.
starts_with_opener <- function(text) {
  grepl("^([~#{(]|D\\{|[sifldrtue][:[{])", text, perl = TRUE)
}

# enc2utf8(), refusing strings that are not valid UTF-8 afterwards: such a
# string has no well-defined bytes to be keyed by.
utf8_text <- function(x, call = rlang::caller_env()) {
  if (any(Encoding(x) == "bytes", na.rm = TRUE)) {
    abort_key_invalid("A key string cannot have \"bytes\" encoding.", call = call)
  }
  x <- enc2utf8(x)
  if (!all(validUTF8(x[!is.na(x)]))) {
    abort_key_invalid("A key string is not valid UTF-8.", call = call)
  }
  x
}

# The value grammar of spec §3.
canon_value <- function(x, call = rlang::caller_env()) {
  if (is.null(x)) {
    return("~")
  }
  if (is_dastash_key(x)) {
    abort_key_invalid(
      "A `dastash_key` cannot be nested inside another key; use its values instead.",
      call = call
    )
  }
  if (isS4(x)) {
    abort_unkeyable(x, call = call)
  }
  if (inherits(x, "POSIXlt")) {
    x <- as.POSIXct(x)
  }
  if (is.data.frame(x)) {
    return(paste0("D", canon_named(unclass(x)[seq_along(x)], names(x), call = call)))
  }
  if (is.list(x)) {
    nms <- names(x)
    if (length(x) == 0L) {
      return("()")
    }
    if (is.null(nms)) {
      parts <- vapply(x, canon_value, character(1), call = call)
      return(paste0("(", paste(parts, collapse = ","), ")"))
    }
    return(canon_named(x, nms, call = call))
  }
  if (is.atomic(x)) {
    return(canon_atomic(x, call = call))
  }
  abort_unkeyable(x, call = call)
}

# A named list or the columns of a data frame: `{name=value,...}`, sorted by
# name in the C locale, so argument and column order are not identity.
canon_named <- function(x, nms, call) {
  check_names(nms, call = call)
  if (anyDuplicated(nms)) {
    abort_key_invalid(
      sprintf("A key cannot repeat the name %s.", encodeString(nms[anyDuplicated(nms)], quote = "\"")),
      call = call
    )
  }
  nms <- utf8_text(nms, call = call)
  ord <- order(nms, method = "radix")
  parts <- vapply(
    ord,
    function(i) paste0(escape_payload(nms[[i]]), "=", canon_value(x[[i]], call = call)),
    character(1)
  )
  paste0("{", paste(parts, collapse = ","), "}")
}

# Names are all or none: an empty or missing name among real ones is refused
# rather than guessed at.
check_names <- function(nms, call) {
  if (anyNA(nms) || !all(nzchar(nms))) {
    abort_key_invalid(
      "Values in a key must be all named or all unnamed.",
      call = call
    )
  }
}

# An atomic vector: `tag:payload` for one unnamed value, `tag[p,...]` for any
# other length, `tag{name=p,...}` when named. Named vectors keep their order,
# since the order of a vector's elements is part of its value.
canon_atomic <- function(x, call) {
  tagged <- atomic_payloads(x, call = call)
  nms <- names(x)
  if (!is.null(nms)) {
    check_names(nms, call = call)
    nms <- escape_payload(utf8_text(nms, call = call))
    body <- paste(paste0(nms, "=", tagged$payload), collapse = ",")
    return(paste0(tagged$tag, "{", body, "}"))
  }
  if (length(x) == 1L) {
    return(paste0(tagged$tag, ":", tagged$payload))
  }
  paste0(tagged$tag, "[", paste(tagged$payload, collapse = ","), "]")
}

# The type tag and the payload of every element. NA is `!` in every type.
atomic_payloads <- function(x, call) {
  if (is.factor(x)) {
    labels <- utf8_text(as.character(x), call = call)
    return(list(tag = "e", payload = na_or(labels, escape_payload)))
  }
  if (inherits(x, "Date")) {
    days <- unclass(x)
    if (any(is.infinite(days))) {
      abort_key_invalid("A `Date` in a key must be finite.", call = call)
    }
    text <- rep("!", length(x))
    ok <- !is.na(days)
    text[ok] <- format(structure(floor(days[ok]), class = "Date"), "%Y-%m-%d")
    return(list(tag = "d", payload = text))
  }
  if (inherits(x, "POSIXct")) {
    return(list(tag = "t", payload = timestamp_payload(unclass(x), call = call)))
  }
  if (inherits(x, "difftime")) {
    secs <- as.numeric(x, units = "secs")
    return(list(tag = "u", payload = number_payload(secs)))
  }
  if (inherits(x, "integer64")) {
    if (!requireNamespace("bit64", quietly = TRUE)) {
      abort_key_invalid("Keying an `integer64` value needs the bit64 package.", call = call)
    }
    text <- as.character(x)
    text[is.na(x)] <- "!"
    return(list(tag = "i", payload = text))
  }
  switch(typeof(x),
    character = list(tag = "s", payload = na_or(utf8_text(x, call = call), escape_payload)),
    integer = list(tag = "i", payload = na_or(x, function(v) sprintf("%d", v))),
    double = list(tag = number_tag(x), payload = number_payload(x)),
    logical = list(tag = "l", payload = ifelse(is.na(x), "!", ifelse(x, "T", "F"))),
    raw = list(tag = "r", payload = sprintf("%02x", as.integer(x))),
    abort_unkeyable(x, call = call)
  )
}

na_or <- function(x, f) {
  out <- rep("!", length(x))
  ok <- !is.na(x)
  out[ok] <- f(x[ok])
  out
}

# A double vector is tagged `i` when every element is a whole number within
# ±2^53 (or NA), so `1L` and `1` agree; otherwise `f`.
number_tag <- function(x) {
  if (all(is.na(x) & !is.nan(x) | is_whole(x))) "i" else "f"
}

is_whole <- function(x) {
  !is.na(x) & is.finite(x) & x == trunc(x) & abs(x) <= 2^53
}

# Whole numbers within ±2^53 in decimal, `-0` as `0`; everything else as an
# exact hexadecimal float; `Inf`, `-Inf` and `NaN` by name; NA as `!`.
number_payload <- function(x) {
  out <- character(length(x))
  whole <- is_whole(x)
  out[whole] <- sprintf("%.0f", x[whole] + 0)
  out[whole & x == 0] <- "0"
  out[is.nan(x)] <- "NaN"
  out[is.na(x) & !is.nan(x)] <- "!"
  out[x %in% Inf] <- "Inf"
  out[x %in% -Inf] <- "-Inf"
  rest <- !whole & is.finite(x)
  out[rest] <- vapply(x[rest], hex_float, character(1))
  out
}

# The C99 `%a` form, computed from the IEEE-754 bits rather than by the C
# library, whose output differs between platforms for subnormals. Normal
# numbers are `[-]0x1.<hex>p<exp>` and subnormals `[-]0x0.<hex>p-1022`, with
# trailing zero digits dropped and the `.` dropped with them.
hex_float <- function(x) {
  bytes <- as.integer(writeBin(x, raw(), size = 8L, endian = "big"))
  negative <- bytes[[1L]] >= 128L
  exponent <- bitwAnd(bytes[[1L]], 0x7FL) * 16L + bitwShiftR(bytes[[2L]], 4L)
  mantissa <- paste0(
    sprintf("%x", bitwAnd(bytes[[2L]], 0x0FL)),
    paste(sprintf("%02x", bytes[3:8]), collapse = "")
  )
  mantissa <- sub("0+$", "", mantissa)
  if (exponent == 0L) {
    lead <- "0"
    power <- -1022L
  } else {
    lead <- "1"
    power <- exponent - 1023L
  }
  paste0(
    if (negative) "-",
    "0x", lead,
    if (nzchar(mantissa)) paste0(".", mantissa),
    "p", if (power >= 0L) "+", power
  )
}

# ISO-8601 in UTC with exactly six fractional digits and `Z`. The instant is
# rounded to the microsecond; the time zone attribute plays no part.
timestamp_payload <- function(secs, call) {
  if (any(is.infinite(secs))) {
    abort_key_invalid("A `POSIXct` in a key must be finite.", call = call)
  }
  out <- rep("!", length(secs))
  ok <- !is.na(secs)
  micros <- round(secs[ok] * 1e6)
  whole <- floor(micros / 1e6)
  frac <- micros - whole * 1e6
  stamp <- format(
    as.POSIXct(whole, origin = "1970-01-01", tz = "UTC"),
    "%Y-%m-%dT%H:%M:%S",
    tz = "UTC"
  )
  out[ok] <- paste0(stamp, ".", sprintf("%06.0f", frac), "Z")
  out
}

# Percent-escape the structural bytes, `%` itself, and control characters.
# Everything else, including non-ASCII UTF-8, is kept as it is.
escape_payload <- function(x) {
  needs <- grepl("[%,=\\[\\]{}():!~\x01-\x1f\x7f]", x, perl = TRUE, useBytes = TRUE)
  x[needs] <- vapply(x[needs], escape_one, character(1), USE.NAMES = FALSE)
  x
}

escape_one <- function(s) {
  bytes <- charToRaw(s)
  special <- as.integer(bytes) %in% c(escape_bytes, 0x01:0x1F, 0x7F)
  parts <- ifelse(special, sprintf("%%%02X", as.integer(bytes)), vapply(bytes, rawToChar, ""))
  out <- paste(parts, collapse = "")
  Encoding(out) <- "UTF-8"
  out
}

escape_bytes <- as.integer(charToRaw("%,=[]{}():!~"))

abort_unkeyable <- function(x, call) {
  what <- if (isS4(x)) {
    "an S4 object"
  } else {
    switch(typeof(x),
      closure = , builtin = , special = "a function",
      environment = "an environment",
      symbol = , language = , expression = , promise = "an unevaluated expression",
      externalptr = "an external pointer",
      complex = "a complex number",
      paste("an object of type", typeof(x))
    )
  }
  abort_key_invalid(
    c(
      sprintf("Cannot use %s in a key.", what),
      i = "Keys cover strings, numbers, logicals, raw, dates, times, factors, lists and data frames.",
      i = "For a memoised function, leave the argument out with `omit =` or supply `key =`."
    ),
    call = call
  )
}

# The key a record is stored under, and the key fields the record keeps
# (design.md §5.3). A key whose text exceeds KEY_MAX is stored as `#` and the
# SHA-256 of its text; the text itself stays in the record up to
# CANON_KEEP_MAX bytes, and a preview beyond that.
key_storage <- function(text) {
  n <- nchar(text, type = "bytes")
  if (n <= KEY_MAX) {
    return(list(stored = text, digested = FALSE))
  }
  out <- list(stored = paste0("#", hash_text(text)), digested = TRUE, key_bytes = n)
  if (n <= CANON_KEEP_MAX) {
    out$key_text <- text
  } else {
    out$key_preview <- utf8_prefix(text, KEY_PREVIEW_MAX)
  }
  out
}

# The longest prefix of `text` that fits in `max_bytes` without splitting a
# UTF-8 character.
utf8_prefix <- function(text, max_bytes) {
  bytes <- charToRaw(text)
  if (length(bytes) <= max_bytes) {
    return(text)
  }
  end <- max_bytes
  # Back up over continuation bytes (10xxxxxx) to the start of a character.
  while (end > 0L && bitwAnd(as.integer(bytes[[end + 1L]]), 0xC0L) == 0x80L) {
    end <- end - 1L
  }
  out <- rawToChar(bytes[seq_len(end)])
  Encoding(out) <- "UTF-8"
  out
}
