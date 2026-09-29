# Codecs: how a value becomes bytes and back (design.md §6.2). A codec is a
# plain classed list and never sees the store: it writes a value to a path and
# reads one back from a path. The record keeps the codec's name and version, and
# decoding dispatches on those, never on the stash's current default.

# Names only the package defines; a user codec cannot take one.
reserved_codec_names <- c("auto", "rds", "raw", "file", "qs2", "parquet", "counter")

#' Codecs
#'
#' @description
#' A codec turns a value into a file and back. The stash records which codec
#' wrote each entry and always decodes with that one, so changing the default
#' never makes stored entries unreadable.
#'
#' * `codec_auto()`, the default, stores a raw vector or a single string as its
#'   bytes (`codec_raw()`) and everything else with `codec_rds()`. It never picks
#'   a codec that loses information or needs a suggested package.
#' * `codec_rds()` stores any R object with [serialize()], losslessly.
#' * `codec_raw()` stores a raw vector, or a single string as its UTF-8 bytes,
#'   exactly as they are.
#' * `codec_file()` stores a copy of an existing file; reading the entry back
#'   gives the path of the stored copy, which is read-only. Always file-backed.
#' * `codec()` defines your own. Every process that reads its entries must pass
#'   it to `stash()` in `codecs`.
#'
#' @param name A name for the codec, not one of the built-in names.
#' @param encode `function(value, path)`: write `value` to the file `path`. It
#'   may return a small named list, stored with the entry and passed back to
#'   `decode()`; anything else it returns is ignored.
#' @param decode `function(path, meta)`: read the value back from `path`.
#'   `meta` is what `encode()` returned, or `NULL`.
#' @param ... Must be empty.
#' @param ext A file extension for the stored file, without the dot, or `NULL`.
#' @param version A whole number, raised when the encoding changes. An entry
#'   written by a newer version than the handle knows is refused.
#' @param supports `function(value)` returning `TRUE` for values the codec
#'   round-trips without loss, or `NULL` for every value.
#' @param compress Passed to [saveRDS()]. Off by default: compression costs more
#'   time than a local disk saves.
#'
#' @return A codec: a list with class `dastash_codec`.
#'
#' @examples
#' codec_auto()
#' codec_rds()
#'
#' # A codec that stores a character vector as lines of text.
#' lines <- codec(
#'   "lines",
#'   encode = function(value, path) writeLines(value, path, useBytes = TRUE),
#'   decode = function(path, meta) readLines(path, encoding = "UTF-8"),
#'   ext = "txt",
#'   supports = function(value) is.character(value) && !anyNA(value)
#' )
#' lines
#' @export
codec <- function(name, encode, decode, ..., ext = NULL, version = 1L, supports = NULL) {
  rlang::check_dots_empty()
  if (!is.character(name) || length(name) != 1L || is.na(name) || !grepl("^[A-Za-z][A-Za-z0-9_.-]*$", name)) {
    abort_codec_error("A codec `name` must be one string of letters, digits, `_`, `.` or `-`, starting with a letter.")
  }
  if (name %in% reserved_codec_names) {
    abort_codec_error(sprintf("The codec name %s is reserved for a built-in codec.", encodeString(name, quote = "\"")), codec = name)
  }
  new_codec(name, encode, decode, ext = ext, version = version, supports = supports)
}

new_codec <- function(name, encode, decode, ext = NULL, version = 1L, supports = NULL,
                      always_file = FALSE, encode_bytes = NULL, decode_bytes = NULL,
                      call = rlang::caller_env()) {
  if (!is.function(encode) || length(formals(encode)) < 2L) {
    abort_codec_error("A codec's `encode` must be a function of `value` and `path`.", codec = name, call = call)
  }
  if (!is.function(decode) || length(formals(decode)) < 2L) {
    abort_codec_error("A codec's `decode` must be a function of `path` and `meta`.", codec = name, call = call)
  }
  if (!is.null(ext) && (!is.character(ext) || length(ext) != 1L || !grepl("^[A-Za-z0-9]+$", ext))) {
    abort_codec_error("A codec's `ext` must be letters and digits, without the dot, or NULL.", codec = name, call = call)
  }
  if (!is.numeric(version) || length(version) != 1L || is.na(version) || version < 1 || version != trunc(version)) {
    abort_codec_error("A codec's `version` must be a whole number of at least 1.", codec = name, call = call)
  }
  if (is.null(supports)) {
    supports <- function(value) TRUE
  }
  if (!is.function(supports)) {
    abort_codec_error("A codec's `supports` must be a function of `value`, or NULL.", codec = name, call = call)
  }
  structure(
    list(
      name = name, version = as.integer(version), ext = ext,
      encode = encode, decode = decode, supports = supports,
      always_file = always_file,
      # Optional in-memory paths, for the built-ins only: a small value is
      # encoded to bytes and decoded from them without a file in between.
      encode_bytes = encode_bytes, decode_bytes = decode_bytes
    ),
    class = "dastash_codec"
  )
}

#' @rdname codec
#' @export
codec_auto <- function() {
  structure(list(name = "auto"), class = c("dastash_codec_auto", "dastash_codec"))
}

#' @rdname codec
#' @export
codec_rds <- function(compress = FALSE) {
  if (!isTRUE(compress) && !isFALSE(compress)) {
    abort_codec_error("`compress` must be TRUE or FALSE.", codec = "rds")
  }
  new_codec(
    "rds",
    encode = function(value, path) {
      saveRDS(value, path, version = 3L, compress = compress)
      NULL
    },
    decode = function(path, meta) readRDS(path),
    ext = "rds",
    # Uncompressed saveRDS() output is exactly serialize()'s, so an inline
    # value's bytes are what the file would have held.
    encode_bytes = if (!compress) function(value) list(bytes = serialize(value, NULL, version = 3L)),
    decode_bytes = function(bytes, meta) {
      if (length(bytes) >= 2L && bytes[[1L]] == as.raw(0x1f) && bytes[[2L]] == as.raw(0x8b)) {
        con <- gzcon(rawConnection(bytes))
        on.exit(close(con))
        return(readRDS(con))
      }
      unserialize(bytes)
    }
  )
}

#' @rdname codec
#' @export
codec_raw <- function() {
  new_codec(
    "raw",
    encode = function(value, path) {
      if (is.raw(value)) {
        writeBin(as.vector(value), path)
        return(list(text = FALSE))
      }
      writeBin(charToRaw(enc2utf8(value)), path)
      list(text = TRUE)
    },
    decode = function(path, meta) {
      bytes <- readBin(path, "raw", n = file.size(path))
      if (!isTRUE(meta$text)) {
        return(bytes)
      }
      text <- rawToChar(bytes)
      Encoding(text) <- "UTF-8"
      text
    },
    supports = function(value) is_bare_raw(value) || is_bare_string(value),
    encode_bytes = function(value) {
      if (is.raw(value)) {
        return(list(bytes = as.vector(value), meta = list(text = FALSE)))
      }
      list(bytes = charToRaw(enc2utf8(value)), meta = list(text = TRUE))
    },
    decode_bytes = function(bytes, meta) {
      if (!isTRUE(meta$text)) {
        return(bytes)
      }
      text <- rawToChar(bytes)
      Encoding(text) <- "UTF-8"
      text
    }
  )
}

#' @rdname codec
#' @export
codec_file <- function() {
  new_codec(
    "file",
    encode = function(value, path) {
      if (!file.copy(value, path, overwrite = TRUE, copy.date = TRUE)) {
        abort_codec_error(sprintf("Could not copy the file %s.", encodeString(value, quote = "\"")), path = value)
      }
      ext <- file_ext(value)
      if (nzchar(ext)) list(ext = ext) else NULL
    },
    decode = function(path, meta) path,
    supports = function(value) {
      is.character(value) && length(value) == 1L && !is.na(value) &&
        file.exists(value) && !dir.exists(value)
    },
    always_file = TRUE
  )
}

#' @export
format.dastash_codec <- function(x, ...) {
  if (inherits(x, "dastash_codec_auto")) {
    return("<dastash_codec> auto: raw for raw vectors and single strings, rds otherwise")
  }
  paste0(
    "<dastash_codec> ", x$name, " v", x$version,
    if (!is.null(x$ext)) paste0(" .", x$ext),
    if (isTRUE(x$always_file)) ", always a file"
  )
}

#' @export
print.dastash_codec <- function(x, ...) {
  cat(format(x), "\n", sep = "")
  invisible(x)
}

is_codec <- function(x) inherits(x, "dastash_codec")

# The concrete codec to write `value` with: `codec_auto()` resolves by value.
codec_for_value <- function(codec, value) {
  if (!inherits(codec, "dastash_codec_auto")) {
    return(codec)
  }
  if (is_bare_raw(value) || is_bare_string(value)) codec_raw() else codec_rds()
}

is_bare_raw <- function(x) {
  is.raw(x) && is.null(attributes(x))
}

is_bare_string <- function(x) {
  is.character(x) && length(x) == 1L && !is.na(x) && is.null(attributes(x)) &&
    Encoding(x) != "bytes" && validUTF8(x)
}

file_ext <- function(path) {
  m <- regexpr("\\.([A-Za-z0-9]+)$", basename(path))
  if (m < 0L) "" else substring(basename(path), m + 1L)
}

# The codec that decodes an entry, found by the name and version its record
# carries: a built-in, or one the handle was given in `codecs`.
codec_lookup <- function(name, version, codecs = list(), call = rlang::caller_env()) {
  codec <- switch(name,
    rds = codec_rds(),
    raw = codec_raw(),
    file = codec_file(),
    counter = codec_counter(),
    codecs[[name]]
  )
  if (is.null(codec)) {
    abort_codec_error(
      c(
        sprintf("This entry was written with the codec %s, which this handle does not know.", encodeString(name, quote = "\"")),
        i = "Pass the codec to `stash()` in `codecs =`."
      ),
      codec = name, call = call
    )
  }
  if (version > codec$version) {
    abort_codec_error(
      sprintf(
        "This entry was written by version %d of the codec %s, newer than the version %d this handle knows.",
        version, encodeString(name, quote = "\""), codec$version
      ),
      codec = name, call = call
    )
  }
  codec
}

# A named list of user codecs, as `stash(codecs =)` takes them, by name.
codec_registry <- function(codecs, call = rlang::caller_env()) {
  if (is_codec(codecs)) {
    codecs <- list(codecs)
  }
  if (!is.list(codecs) || !all(vapply(codecs, is_codec, logical(1)))) {
    abort_codec_error("`codecs` must be a list of codecs made with `codec()`.", call = call)
  }
  nms <- vapply(codecs, function(c) c$name, character(1))
  if (any(nms %in% reserved_codec_names) || anyDuplicated(nms)) {
    abort_codec_error("`codecs` must hold user codecs with distinct, non-reserved names.", call = call)
  }
  names(codecs) <- nms
  codecs
}

# Write `value` to `path` with `codec`, checking first that the codec can hold
# it. Returns what the record keeps about the encoding.
codec_encode <- function(codec, value, path, call = rlang::caller_env()) {
  if (!isTRUE(codec$supports(value))) {
    abort_type_error(
      sprintf("The codec %s cannot store this value without loss.", encodeString(codec$name, quote = "\"")),
      codec = codec$name, call = call
    )
  }
  meta <- tryCatch(
    codec$encode(value, path),
    dastash_error = function(cnd) rlang::cnd_signal(cnd),
    error = function(cnd) {
      abort_codec_error(
        sprintf("The codec %s failed to encode the value.", encodeString(codec$name, quote = "\"")),
        codec = codec$name, parent = cnd, call = call
      )
    }
  )
  if (!is.list(meta) || length(meta) == 0L || is.null(names(meta))) {
    meta <- NULL
  }
  list(codec = codec$name, version = codec$version, meta = meta, ext = meta$ext %||% codec$ext)
}

codec_decode <- function(codec, path, meta, call = rlang::caller_env()) {
  tryCatch(
    codec$decode(path, meta),
    dastash_error = function(cnd) rlang::cnd_signal(cnd),
    error = function(cnd) {
      abort_codec_error(
        sprintf("The codec %s failed to decode the stored value.", encodeString(codec$name, quote = "\"")),
        codec = codec$name, path = path, parent = cnd, call = call
      )
    }
  )
}


# Encode `value` for storage: in memory when the codec can, otherwise into the
# staging file `stage()` names. Returns the bytes or the file, its size, and
# what the record keeps about the encoding.
codec_encode_value <- function(codec, value, stage, call = rlang::caller_env()) {
  if (!isTRUE(codec$supports(value))) {
    abort_type_error(
      sprintf("The codec %s cannot store this value without loss.", encodeString(codec$name, quote = "\"")),
      codec = codec$name, call = call
    )
  }
  if (!is.null(codec$encode_bytes) && !isTRUE(codec$always_file)) {
    out <- codec_guard(codec, "encode", call, codec$encode_bytes(value))
    return(list(
      bytes = out$bytes, path = NULL, size = length(out$bytes),
      codec = codec$name, version = codec$version, meta = out$meta,
      ext = out$meta$ext %||% codec$ext
    ))
  }
  path <- stage()
  info <- codec_encode(codec, value, path, call = call)
  c(list(bytes = NULL, path = path, size = file.size(path)), info)
}

# Decode an inline value from its bytes, through a file only for codecs that
# cannot read bytes directly.
codec_decode_bytes <- function(codec, bytes, meta, stage, call = rlang::caller_env()) {
  if (!is.null(codec$decode_bytes)) {
    return(codec_guard(codec, "decode", call, codec$decode_bytes(bytes, meta)))
  }
  path <- stage()
  on.exit(unlink(path))
  writeBin(bytes, path)
  codec_decode(codec, path, meta, call = call)
}

# Evaluate a codec's own code, turning its failures into dastash_codec_error.
codec_guard <- function(codec, what, call, expr) {
  tryCatch(
    expr,
    dastash_error = function(cnd) rlang::cnd_signal(cnd),
    error = function(cnd) {
      abort_codec_error(
        sprintf("The codec %s failed to %s the value.", encodeString(codec$name, quote = "\""), what),
        codec = codec$name, parent = cnd, call = call
      )
    }
  )
}
