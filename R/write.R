# Writing (design.md §3.4). A value is encoded before the write transaction
# begins, so the transaction holds the lock only while it updates records.

#' Write to a stash
#'
#' @description
#' `stash_set()` stores a value under a key, replacing any entry there.
#' `stash_mset()` stores every element of a named list, in one transaction.
#' `stash_delete()` removes the entries for the keys given, in one transaction;
#' keys with no entry are ignored.
#'
#' All three return the stash invisibly, so they chain with `|>`.
#'
#' @inheritParams stash_get
#' @param value The value to store.
#' @param values A named list: each name is a key, each element its value.
#' @param ... Must be empty.
#' @param expire Not yet supported: leave as `NULL`.
#' @param tags Not yet supported: leave as `NULL`.
#' @param codec The codec to write with, or `NULL` for the stash's default. See
#'   [codec()].
#'
#' @return The stash, invisibly.
#'
#' @examples
#' s <- local_stash()
#' s |>
#'   stash_set("a", 1) |>
#'   stash_mset(list(b = "two", c = 3:5))
#' stash_keys(s)
#' stash_delete(s, c("a", "b"))
#' stash_keys(s)
#' @export
stash_set <- function(stash, key, value, ..., expire = NULL, tags = NULL, codec = NULL) {
  rlang::check_dots_empty()
  check_writable(stash)
  entry <- stash_prepare(stash, key, value, expire, tags, codec)
  engine_write(stash$engine, function(txn) {
    store_put_entry(stash, txn, entry$key, entry$enc, unclass(Sys.time()))
  }, timeout = stash$timeout)
  invisible(stash)
}

#' @rdname stash_set
#' @export
stash_mset <- function(stash, values, ..., expire = NULL, tags = NULL, codec = NULL) {
  rlang::check_dots_empty()
  check_writable(stash)
  nms <- names(values)
  if (!is.list(values) || (length(values) > 0L && (is.null(nms) || anyNA(nms) || !all(nzchar(nms))))) {
    abort_type_error("`values` must be a named list: each name a key, each element its value.")
  }
  entries <- lapply(seq_along(values), function(i) {
    stash_prepare(stash, nms[[i]], values[[i]], expire, tags, codec)
  })
  engine_write(stash$engine, function(txn) {
    now <- unclass(Sys.time())
    for (entry in entries) store_put_entry(stash, txn, entry$key, entry$enc, now)
  }, timeout = stash$timeout)
  invisible(stash)
}

#' @rdname stash_set
#' @export
stash_delete <- function(stash, keys) {
  check_writable(stash)
  infos <- lapply(as_key_list(keys), store_key)
  engine_write(stash$engine, function(txn) {
    for (key in infos) store_delete_entry(stash, txn, key$stored)
  }, timeout = stash$timeout)
  invisible(stash)
}

# Encode one value for writing, outside any transaction: the key, the codec
# that will write it, and its bytes.
stash_prepare <- function(s, key, value, expire, tags, codec, call = rlang::caller_env()) {
  if (!is.null(expire) && !identical(expire, Inf)) {
    abort_unsupported("`expire` is not supported yet.", call = call)
  }
  if (length(tags) > 0L) {
    abort_unsupported("`tags` is not supported yet.", call = call)
  }
  key <- store_key(key, call = call)
  codec <- codec %||% s$codec
  if (is.null(codec)) {
    abort_codec_error(
      c(
        sprintf("This stash's default codec is %s, which this handle does not know.", encodeString(s$config$codec, quote = "\"")),
        i = "Pass it to `stash()` in `codecs =`, or give `codec =` here."
      ),
      codec = s$config$codec, call = call
    )
  }
  if (!is_codec(codec)) {
    abort_codec_error("`codec` must be a codec, such as `codec_rds()`.", call = call)
  }
  codec <- codec_for_value(codec, value)
  enc <- codec_encode_value(codec, value, stage = function() stage_path(s), call = call)
  if (isTRUE(codec$always_file) || enc$size >= s$config$inline_max) {
    if (!is.null(enc$path)) unlink(enc$path)
    abort_unsupported(
      sprintf(
        "This value encodes to %s bytes, and values of `inline_max` (%s bytes) or more are not supported yet.",
        format(enc$size), format(s$config$inline_max)
      ),
      call = call
    )
  }
  if (!is.null(enc$path)) {
    enc$bytes <- readBin(enc$path, "raw", n = enc$size)
    unlink(enc$path)
    enc$path <- NULL
  }
  list(key = key, enc = enc)
}
