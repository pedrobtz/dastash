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
  value <- if (!is.null(hit)) store_decode_entry(stash, hit, key)
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

#' @rdname stash_get
#' @export
stash_mget <- function(stash, keys, default) {
  check_open(stash)
  infos <- lapply(as_key_list(keys), store_key)
  hits <- engine_read(stash$engine, function(txn) {
    lapply(infos, function(key) store_read_entry(stash, txn, key))
  })
  values <- lapply(seq_along(hits), function(i) {
    if (!is.null(hits[[i]])) store_decode_entry(stash, hits[[i]], infos[[i]])
  })
  absent <- vapply(values, is.null, logical(1))
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
  out <- vector("list", length(values))
  for (i in seq_along(values)) {
    out[i] <- if (is.null(values[[i]])) list(default) else values[[i]]
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
#' `stash_count()` returns the number of entries, including expired ones that
#' [stash_expire()] has not reclaimed yet. `stash_volume()` returns the bytes
#' the stash occupies on disk: its database file and every stored file.
#'
#' @inheritParams stash_get
#' @param ... Must be empty.
#' @param prefix Only keys whose text begins with this string.
#' @param start Begin at this key, inclusive.
#' @param n The most keys to return.
#'
#' @return `stash_keys()` returns a character vector, `stash_count()` an integer,
#'   and `stash_volume()` a number of bytes.
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
  if (isTRUE(record$inline)) {
    return(list(record = record, bytes = engine_get(txn, engine_db(s$engine, "values"), key$stored)))
  }
  list(record = record, path = blob_path(s, record_blob_name(record)))
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

# The value of an entry read by store_read_entry(), wrapped in a list, or NULL
# if its file went before it could be read.
store_decode_entry <- function(s, hit, key, call = rlang::caller_env()) {
  record <- hit$record
  codec <- codec_lookup(record$codec, record$codec_version, s$codecs, call = call)
  if (isTRUE(record$inline)) {
    return(list(codec_decode_bytes(codec, hit$bytes, record$codec_meta, stage = function() stage_path(s), call = call)))
  }
  # A read transaction has ended by now, so another process may delete or
  # replace the entry, and unlink its file, at any moment: before the size is
  # checked, or between the check and the decoder opening the file. Either way
  # the entry is gone, which a cache may always answer as a miss (design.md
  # §4). Only a record that still names a file that stays missing is damage.
  for (attempt in 1:3) {
    if (!store_blob_ready(s, hit, key, call)) {
      return(NULL)
    }
    value <- tryCatch(
      withCallingHandlers(
        list(codec_decode(codec, hit$path, record$codec_meta, call = call)),
        # A decoder's "cannot open file" warning, when the file just went.
        warning = function(cnd) if (!file.exists(hit$path)) invokeRestart("muffleWarning")
      ),
      dastash_codec_error = function(cnd) {
        if (file.exists(hit$path)) rlang::cnd_signal(cnd)
        NULL
      }
    )
    if (!is.null(value)) {
      return(value)
    }
  }
  NULL
}

# TRUE when the blob's file is there at the size its record holds; FALSE when
# the entry has since been deleted or now names another file (a miss); an
# error when the record still names a file that is missing or the wrong size.
# The size is what a crash before the data reached the disk would leave wrong;
# stash_check(hash = TRUE) verifies the bytes themselves.
store_blob_ready <- function(s, hit, key, call) {
  record <- hit$record
  size <- file.size(hit$path)
  if (is.na(size)) {
    current <- engine_read(s$engine, function(txn) store_live_record(s, txn, key))
    if (is.null(current) || !identical(record_blob_name(current), record_blob_name(record))) {
      return(FALSE)
    }
    # The same bytes may have been stored again after we looked.
    size <- file.size(hit$path)
    if (is.na(size)) {
      abort_blob_corrupt(
        sprintf("The file behind key %s is missing.", display_key(key$text)),
        key = key$text, path = hit$path, call = call
      )
    }
  }
  if (size != record$bytes) {
    abort_blob_corrupt(
      sprintf(
        "The file behind key %s has %s bytes where %s were written.",
        display_key(key$text), format(size), format(record$bytes)
      ),
      key = key$text, path = hit$path, call = call
    )
  }
  TRUE
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

#' The file behind an entry
#'
#' @description
#' An entry of `inline_max` bytes or more, or one written with a file-backed
#' codec such as [codec_file()], is stored as a file. `stash_path()` returns its
#' path without reading it, so other tools can read it in place.
#'
#' The file is read-only, and identical content is one file however many keys
#' refer to it. The path is valid while the entry lives: deleting, replacing
#' or expiring the entry, from any process, may remove the file. Copy the file
#' if you need it to outlive the entry.
#'
#' @inheritParams stash_get
#'
#' @return The path, a string. A missing key is a `dastash_not_found` error,
#'   and an entry stored inline a `dastash_type_error`.
#'
#' @examples
#' s <- local_stash()
#' stash_set(s, "numbers", runif(1e5))
#' path <- stash_path(s, "numbers")
#' file.size(path)
#' identical(readRDS(path), stash_get(s, "numbers"))
#' @export
stash_path <- function(stash, key) {
  check_open(stash)
  key <- store_key(key)
  record <- engine_read(stash$engine, function(txn) store_live_record(stash, txn, key))
  if (is.null(record)) {
    abort_not_found(sprintf("No entry for key %s.", display_key(key$text)), key = key$text)
  }
  if (isTRUE(record$inline)) {
    abort_type_error(
      c(
        sprintf("The entry for key %s is stored inline, not as a file.", display_key(key$text)),
        i = "Values smaller than `inline_max` are kept in the database."
      ),
      key = key$text
    )
  }
  blob_path(stash, record_blob_name(record))
}

#' @rdname stash_keys
#' @export
stash_volume <- function(stash) {
  check_open(stash)
  counters <- engine_read(stash$engine, store_counters)
  as.double(engine_info(stash$engine)$file_size) + counters$bytes_blob
}
