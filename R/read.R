# Reading (design.md §3.3) and enumerating (§3.5). Every verb here is one read
# transaction: it never writes, and it decodes values only after the
# transaction has returned their bytes.

#' Read from a stash
#'
#' @description
#' `stash_get()` returns the value stored under a key. A missing key is an error
#' of class `dastash_not_found` unless `default` is supplied, in which case
#' `default` is returned; a stored `NULL` is a value like any other.
#'
#' `stash_mget()` reads several keys at once and returns a named list in the
#' order asked. `stash_has()` says which keys have an entry.
#'
#' A key is a string, a key from [stash_key()], or any value that can be a key;
#' see [stash_key()].
#'
#' @param stash A stash, from [stash()].
#' @param key A key.
#' @param keys A character vector of keys, or a list of keys.
#' @param default Returned for a missing key. Leave it out to make a missing key
#'   an error.
#'
#' @return `stash_get()` returns the value. `stash_mget()` returns a list named
#'   by each key's text. `stash_has()` returns a logical vector, one element per
#'   key.
#'
#' @examples
#' s <- local_stash()
#' stash_set(s, "a", 1)
#' stash_get(s, "a")
#' stash_get(s, "b", default = NA)
#' try(stash_get(s, "b"))
#'
#' stash_has(s, c("a", "b"))
#' stash_mget(s, c("a", "b"), default = NULL)
#' @export
stash_get <- function(stash, key, default) {
  check_open(stash)
  key <- store_key(key)
  hit <- engine_read(stash$engine, function(txn) store_read_entry(stash, txn, key))
  if (is.null(hit)) {
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
  store_decode_entry(stash, hit)
}

#' @rdname stash_get
#' @export
stash_mget <- function(stash, keys, default) {
  check_open(stash)
  infos <- lapply(as_key_list(keys), store_key)
  hits <- engine_read(stash$engine, function(txn) {
    lapply(infos, function(key) store_read_entry(stash, txn, key))
  })
  absent <- vapply(hits, is.null, logical(1))
  if (any(absent) && missing(default)) {
    abort_not_found(
      c(
        sprintf(
          "No entry for key %s%s.",
          display_key(infos[[which(absent)[[1L]]]]$text),
          if (sum(absent) > 1L) sprintf(" and %d more", sum(absent) - 1L) else ""
        ),
        i = "Supply `default` to return a value for missing keys instead of erroring."
      ),
      key = vapply(infos[absent], function(k) k$text, character(1))
    )
  }
  out <- vector("list", length(hits))
  for (i in seq_along(hits)) {
    if (!is.null(hits[[i]])) out[i] <- list(store_decode_entry(stash, hits[[i]]))
    else out[i] <- list(default)
  }
  names(out) <- vapply(infos, function(k) k$text, character(1))
  out
}

#' @rdname stash_get
#' @export
stash_has <- function(stash, keys) {
  check_open(stash)
  infos <- lapply(as_key_list(keys), store_key)
  engine_read(stash$engine, function(txn) {
    vapply(infos, function(key) !is.null(store_live_record(stash, txn, key)), logical(1))
  })
}

#' List and count a stash's entries
#'
#' @description
#' `stash_keys()` returns keys in key order: the text of each key, as
#' [stash_key_chr()] gives it. Use `prefix` for keys that begin with a string,
#' and `start` with `n` to page through a large stash: `start` is inclusive, so
#' drop the first key of every page after the first.
#'
#' `stash_count()` returns the number of entries.
#'
#' @inheritParams stash_get
#' @param ... Must be empty.
#' @param prefix Only keys whose text begins with this string.
#' @param start Begin at this key, inclusive.
#' @param n The most keys to return.
#'
#' @return `stash_keys()` returns a character vector; `stash_count()` an integer.
#'
#' @examples
#' s <- local_stash()
#' for (k in c("prices/a", "prices/b", "volumes/a")) stash_set(s, k, 1)
#' stash_keys(s)
#' stash_keys(s, prefix = "prices/")
#' stash_keys(s, start = "prices/b", n = 2)
#' stash_count(s)
#' @export
stash_keys <- function(stash, ..., prefix = NULL, start = NULL, n = Inf) {
  rlang::check_dots_empty()
  check_open(stash)
  if (!is.null(prefix)) check_string_or_empty(prefix, "prefix")
  check_number(n, "n", rlang::current_env(), min = 0, whole = TRUE, allow_inf = TRUE)
  from <- if (!is.null(start)) store_key(start)$stored
  e <- stash$engine
  now <- unclass(Sys.time())
  engine_read(e, function(txn) {
    out <- character()
    first <- TRUE
    # Expired entries are skipped, so filling a page of `n` can take more than
    # one scan. The records come with the keys, so skipping costs no lookup.
    repeat {
      remaining <- n - length(out)
      ask <- if (is.finite(remaining)) remaining + !first else Inf
      got <- engine_scan(
        txn, engine_db(e, "meta"),
        prefix = prefix, start = from, n = ask, as = "character", values = TRUE
      )
      keys <- got$keys
      records <- lapply(got$values, record_decode)
      if (!first && length(keys) > 0L) {
        keys <- keys[-1L]
        records <- records[-1L]
      }
      live <- vapply(records, is_live, logical(1), now = now)
      shown <- vapply(seq_along(keys), function(i) {
        if (startsWith(keys[[i]], "#")) records[[i]]$key_text %||% keys[[i]] else keys[[i]]
      }, character(1))
      out <- c(out, shown[live])
      if (!is.finite(ask) || length(got$keys) < ask || length(out) >= n) break
      from <- got$keys[[length(got$keys)]]
      first <- FALSE
    }
    out[seq_len(min(length(out), n))]
  })
}

#' @rdname stash_keys
#' @export
stash_count <- function(stash) {
  check_open(stash)
  e <- stash$engine
  as.integer(engine_read(e, function(txn) engine_count(txn, engine_db(e, "meta"))))
}

# Helpers --------------------------------------------------------------------

# The record and inline bytes of a live entry, or NULL.
store_read_entry <- function(s, txn, key) {
  record <- store_live_record(s, txn, key)
  if (is.null(record)) {
    return(NULL)
  }
  list(record = record, bytes = engine_get(txn, engine_db(s$engine, "values"), key$stored))
}

# The record under `key`, if it is the key asked for and has not expired.
# Expiry is part of the read: an entry past its deadline is absent to every
# reader before anything deletes it (design.md §4, §9.1).
store_live_record <- function(s, txn, key, now = unclass(Sys.time())) {
  record <- store_get_record(s, txn, key$stored)
  if (is.null(record) || !store_record_matches(record, key) || !is_live(record, now)) {
    return(NULL)
  }
  record
}

is_live <- function(record, now) {
  now < record$expire
}

store_decode_entry <- function(s, hit, call = rlang::caller_env()) {
  record <- hit$record
  codec <- codec_lookup(record$codec, record$codec_version, s$codecs, call = call)
  codec_decode_bytes(codec, hit$bytes, record$codec_meta, stage = function() stage_path(s), call = call)
}

# `keys` as a list of keys: a character or other atomic vector is one key per
# element; a single `dastash_key` is one key.
as_key_list <- function(keys) {
  if (is_dastash_key(keys)) {
    return(list(keys))
  }
  if (is.atomic(keys)) {
    return(as.list(unname(keys)))
  }
  if (is.list(keys)) {
    return(unname(keys))
  }
  abort_type_error("`keys` must be a character vector of keys or a list of keys.", call = rlang::caller_env(2))
}

display_key <- function(text, max = 80L) {
  if (nchar(text) > max) text <- paste0(substr(text, 1L, max - 1L), "\u2026")
  encodeString(text, quote = "\"")
}

check_string_or_empty <- function(x, arg, call = rlang::caller_env()) {
  if (!is.character(x) || length(x) != 1L || is.na(x)) {
    abort_type_error(sprintf("`%s` must be a single string.", arg), call = call)
  }
}
