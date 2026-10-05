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
#' @param expire When the entry expires: `NULL` or `Inf` for never; a number of
#'   seconds from now (zero or less means already expired); a [difftime] from
#'   now; or a [POSIXct] for an absolute time. An expired entry is absent to
#'   every read at once, and [stash_expire()] reclaims its space.
#' @param tags A character vector of up to 16 tags, each at most 256 bytes, to
#'   group entries for [stash_evict()] and [stash_entries()].
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
  on.exit(unstage(list(entry)))
  engine_write(stash$engine, function(txn) {
    store_put_entry(stash, txn, entry$key, entry$enc, unclass(Sys.time()), expire = entry$expire, tags = entry$tags)
    store_cull_step(stash, txn, protect = entry$key$stored)
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
  entries <- list()
  on.exit(unstage(entries))
  for (i in seq_along(values)) {
    entries[[i]] <- stash_prepare(stash, nms[[i]], values[[i]], expire, tags, codec)
  }
  engine_write(stash$engine, function(txn) {
    now <- unclass(Sys.time())
    for (entry in entries) store_put_entry(stash, txn, entry$key, entry$enc, now, expire = entry$expire, tags = entry$tags)
    store_cull_step(stash, txn, protect = vapply(entries, function(x) x$key$stored, character(1)))
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
  deadline <- parse_expire(expire, unclass(Sys.time()), call = call)
  tags <- parse_tags(tags, call = call)
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
  # Until the entry is returned, its staged file is this function's to remove.
  staged <- enc$path
  on.exit(if (!is.null(staged)) unlink(staged))
  if (isTRUE(codec$always_file) || enc$size >= s$config$inline_max) {
    # A file: staged in <root>/tmp and hashed now, published in the transaction.
    enc$blob <- blob_stage(s, enc)
    enc$bytes <- NULL
    enc$path <- NULL
  } else if (!is.null(enc$path)) {
    enc$bytes <- readBin(enc$path, "raw", n = enc$size)
    unlink(enc$path)
    enc$path <- NULL
  }
  out <- list(key = key, enc = enc, expire = deadline, tags = tags)
  staged <- NULL
  out
}

# `tags` as a sorted, unique character vector (design.md §3.4).
parse_tags <- function(tags, call = rlang::caller_env()) {
  if (is.null(tags)) {
    return(character())
  }
  if (!is.character(tags) || anyNA(tags) || !all(nzchar(tags))) {
    abort_type_error("`tags` must be a character vector of non-empty strings.", call = call)
  }
  tags <- utf8_text(unique(tags), call = call)
  if (length(tags) > 16L) {
    abort_type_error("An entry can carry at most 16 tags.", call = call)
  }
  if (any(nchar(tags, type = "bytes") > TAG_MAX)) {
    abort_type_error(sprintf("A tag can be at most %d bytes.", TAG_MAX), call = call)
  }
  sort(tags, method = "radix")
}

# An `expire` argument as an absolute deadline in epoch seconds: Inf for never.
parse_expire <- function(expire, now, call = rlang::caller_env()) {
  if (is.null(expire)) {
    return(Inf)
  }
  if (length(expire) != 1L || !is.numeric(unclass(expire)) || is.na(expire)) {
    abort_type_error(
      "`expire` must be NULL, a number of seconds, a difftime, or a POSIXct; not NA or NaN.",
      call = call
    )
  }
  if (inherits(expire, "POSIXct")) {
    return(as.double(unclass(expire)))
  }
  if (inherits(expire, "difftime")) {
    return(now + as.double(expire, units = "secs"))
  }
  if (inherits(expire, "POSIXlt") || !is.null(attr(expire, "class"))) {
    abort_type_error("`expire` must be NULL, a number of seconds, a difftime, or a POSIXct.", call = call)
  }
  now + as.double(expire)
}

#' Atomic writes
#'
#' @description
#' Each of these is one transaction, so it is atomic across processes: eight
#' processes calling `stash_incr()` on one key produce eight increments.
#'
#' * `stash_add()` writes only if the key has no entry, and returns whether it
#'   did. An expired entry counts as none.
#' * `stash_pop()` returns an entry's value and deletes it.
#' * `stash_touch()` gives an entry a new deadline without rewriting its value.
#'   It does nothing to a missing key.
#' * `stash_incr()` and `stash_decr()` add to or subtract from a counter and
#'   return its new value. A missing key starts at `default`. Counters hold
#'   whole numbers within ±2^53; a key holding anything else is a
#'   `dastash_type_error`.
#'
#' @inheritParams stash_set
#' @param by The amount to add or subtract, a whole number.
#' @param default For `stash_pop()`, returned for a missing key; leave it out to
#'   make a missing key an error. For the counters, the starting value.
#'
#' @return `stash_add()` returns `TRUE` or `FALSE`. `stash_pop()` returns the
#'   value. `stash_touch()` returns the stash, invisibly. `stash_incr()` and
#'   `stash_decr()` return the new count, a double.
#'
#' @examples
#' s <- local_stash()
#' stash_add(s, "lock", Sys.getpid(), expire = 30)
#' stash_add(s, "lock", Sys.getpid())
#'
#' stash_incr(s, "hits")
#' stash_incr(s, "hits", by = 10)
#' stash_decr(s, "hits")
#'
#' stash_set(s, "job", "payload")
#' stash_pop(s, "job")
#' stash_has(s, "job")
#' @export
stash_add <- function(stash, key, value, ..., expire = NULL, tags = NULL, codec = NULL) {
  rlang::check_dots_empty()
  check_writable(stash)
  entry <- stash_prepare(stash, key, value, expire, tags, codec)
  on.exit(unstage(list(entry)))
  engine_write(stash$engine, function(txn) {
    now <- unclass(Sys.time())
    if (!is.null(store_live_record(stash, txn, entry$key, now))) {
      return(FALSE)
    }
    store_put_entry(stash, txn, entry$key, entry$enc, now, expire = entry$expire, tags = entry$tags)
    store_cull_step(stash, txn, protect = entry$key$stored)
    TRUE
  }, timeout = stash$timeout)
}

#' @rdname stash_add
#' @export
stash_pop <- function(stash, key, default) {
  check_writable(stash)
  key <- store_key(key)
  e <- stash$engine
  nested <- !is.null(e$txn)
  value <- NULL
  hit <- engine_write(e, function(txn) {
    found <- store_read_entry(stash, txn, key)
    if (is.null(found)) {
      return(NULL)
    }
    if (!nested && !isTRUE(found$record$inline)) {
      # The file is unlinked after the commit; read it first. (Inside
      # stash_transact() it stays until the outer commit.)
      engine_defer(e, function() value <<- store_decode_entry(stash, found, key))
    }
    store_delete_entry(stash, txn, key$stored)
    found
  }, timeout = stash$timeout)
  if (!is.null(hit) && is.null(value)) {
    value <- store_decode_entry(stash, hit, key)
  }
  if (is.null(value)) {
    if (missing(default)) {
      abort_not_found(
        c(
          sprintf("No entry for key %s.", display_key(key$text)),
          i = "Supply `default` to return a value instead of erroring."
        ),
        key = key$text
      )
    }
    return(default)
  }
  value[[1L]]
}

#' @rdname stash_add
#' @export
stash_touch <- function(stash, key, expire) {
  check_writable(stash)
  key <- store_key(key)
  deadline <- parse_expire(expire, unclass(Sys.time()))
  engine_write(stash$engine, function(txn) {
    old <- store_live_record(stash, txn, key)
    if (!is.null(old)) {
      record <- old
      record$expire <- deadline
      store_update_record(stash, txn, key$stored, old, record)
    }
  }, timeout = stash$timeout)
  invisible(stash)
}

# Remove whatever staging files these prepared entries left: those whose blob
# was already stored, or whose transaction did not commit. A published file
# was renamed away and is not touched.
unstage <- function(entries) {
  for (entry in entries) {
    if (!is.null(entry$enc$blob)) blob_unlink(entry$enc$blob$staged)
  }
}
