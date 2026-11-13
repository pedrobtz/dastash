# Writing (design.md §3.4). A value is encoded before the write transaction
# begins, so the transaction holds the lock only while it updates records.

#' Write to a cache
#'
#' @description
#' `cache_set()` stores a value under a key, replacing any entry there.
#' `cache_mset()` stores every element of a named list, in one transaction.
#' `cache_delete()` removes the entries for the keys given, in one transaction;
#' keys with no entry are ignored.
#'
#' All three return the cache invisibly, so they chain with `|>`.
#'
#' @inheritParams cache_get
#' @param value The value to store.
#' @param values A named list: each name is a key, each element its value.
#' @param ... Must be empty.
#' @param expire When the entry expires: `NULL` or `Inf` for never; a number of
#'   seconds from now (zero or less means already expired); a [difftime] from
#'   now; or a [POSIXct] for an absolute time. An expired entry is absent to
#'   every read at once, and [cache_expire()] reclaims its space.
#' @param tags A character vector of up to 16 tags, each at most 256 bytes, to
#'   group entries for [cache_evict()] and [cache_entries()].
#' @param codec The codec to write with, or `NULL` for the cache's default. See
#'   [codec()].
#'
#' @return The cache, invisibly.
#'
#' @examples
#' s <- local_cache()
#' s |>
#'   cache_set("a", 1) |>
#'   cache_mset(list(b = "two", c = 3:5))
#' cache_keys(s)
#' cache_delete(s, c("a", "b"))
#' cache_keys(s)
#' @export
cache_set <- function(
  cache,
  key,
  value,
  ...,
  expire = NULL,
  tags = NULL,
  codec = NULL
) {
  check_supplied(c("key", "value"))
  rlang::check_dots_empty()
  check_writable(cache)
  entry <- cache_prepare(cache, key, value, expire, tags, codec)
  on.exit(unstage(list(entry)))
  engine_write(
    cache$engine,
    function(txn) {
      store_put_entry(
        cache,
        txn,
        entry$key,
        entry$enc,
        unclass(Sys.time()),
        expire = entry$expire,
        tags = entry$tags
      )
      store_cull_step(cache, txn, protect = entry$key$stored)
    },
    timeout = cache$timeout
  )
  invisible(cache)
}

#' @rdname cache_set
#' @export
cache_mset <- function(
  cache,
  values,
  ...,
  expire = NULL,
  tags = NULL,
  codec = NULL
) {
  check_supplied("values")
  rlang::check_dots_empty()
  check_writable(cache)
  if (!is_named_list(values)) {
    abort_type_error(
      "`values` must be a named list: each name a key, each element its value."
    )
  }
  entries <- list()
  on.exit(unstage(entries))
  nms <- names(values)
  for (i in seq_along(values)) {
    entries[[i]] <- cache_prepare(
      cache,
      nms[[i]],
      values[[i]],
      expire,
      tags,
      codec
    )
  }
  engine_write(
    cache$engine,
    function(txn) {
      now <- unclass(Sys.time())
      # One cull step per entry, as a run of cache_set() calls would take, so a
      # batch larger than the limit cannot leave the cache far over it.
      for (entry in entries) {
        store_put_entry(
          cache,
          txn,
          entry$key,
          entry$enc,
          now,
          expire = entry$expire,
          tags = entry$tags
        )
        store_cull_step(cache, txn, protect = entry$key$stored)
      }
    },
    timeout = cache$timeout
  )
  invisible(cache)
}

#' @rdname cache_set
#' @export
cache_delete <- function(cache, keys) {
  check_supplied("keys")
  check_writable(cache)
  infos <- store_keys(keys)
  engine_write(
    cache$engine,
    function(txn) {
      for (key in infos) {
        store_delete_entry(cache, txn, key$stored)
      }
    },
    timeout = cache$timeout
  )
  invisible(cache)
}

# A list whose every element has a name; an empty list is one.
is_named_list <- function(x) {
  nms <- names(x)
  is.list(x) &&
    (length(x) == 0L || (!is.null(nms) && !anyNA(nms) && all(nzchar(nms))))
}

# Encode one value for writing, outside any transaction: the key, the codec
# that will write it, and its bytes.
cache_prepare <- function(
  s,
  key,
  value,
  expire,
  tags,
  codec,
  call = rlang::caller_env()
) {
  deadline <- parse_expire(expire, unclass(Sys.time()), call = call)
  tags <- parse_tags(tags, call = call)
  key <- store_key(key, call = call)
  codec <- codec %||% s$codec
  if (is.null(codec)) {
    abort_codec_error(
      c(
        sprintf(
          "This cache's default codec is %s, which this handle does not know.",
          encodeString(s$config$codec, quote = "\"")
        ),
        i = "Pass it to `cache()` in `codecs =`, or give `codec =` here."
      ),
      codec = s$config$codec,
      call = call
    )
  }
  if (!is_codec(codec)) {
    abort_codec_error(
      "`codec` must be a codec, such as `codec_rds()`.",
      call = call
    )
  }
  codec_register(s, codec)
  codec <- codec_for_value(codec, value)
  enc <- codec_encode_value(
    codec,
    value,
    stage = function() stage_path(s),
    call = call
  )
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
    abort_type_error(
      "`tags` must be a character vector of non-empty strings.",
      call = call
    )
  }
  tags <- utf8_text(unique(tags), call = call)
  if (length(tags) > 16L) {
    abort_type_error("An entry can carry at most 16 tags.", call = call)
  }
  if (any(nchar(tags, type = "bytes") > TAG_MAX)) {
    abort_type_error(
      sprintf("A tag can be at most %d bytes.", TAG_MAX),
      call = call
    )
  }
  sort(tags, method = "radix")
}

# An `expire` argument as an absolute deadline in epoch seconds: Inf for never.
# A deadline of -Inf is now: already expired, like any other past deadline, and
# finite, so the entry has an expiry row and cache_expire() reclaims it.
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
  deadline <- if (inherits(expire, "POSIXct")) {
    as.double(unclass(expire))
  } else if (inherits(expire, "difftime")) {
    now + as.double(expire, units = "secs")
  } else if (is.object(expire)) {
    abort_type_error(
      "`expire` must be NULL, a number of seconds, a difftime, or a POSIXct.",
      call = call
    )
  } else {
    now + as.double(expire)
  }
  if (deadline == -Inf) now else deadline
}

#' Atomic writes
#'
#' @description
#' Each of these is one transaction, so it is atomic across processes: eight
#' processes calling `cache_incr()` on one key produce eight increments.
#'
#' * `cache_add()` writes only if the key has no entry, and returns whether it
#'   did. An expired entry counts as none.
#' * `cache_pop()` returns an entry's value and deletes it.
#' * `cache_touch()` gives an entry a new deadline without rewriting its value.
#'   It does nothing to a missing key.
#' * `cache_incr()` and `cache_decr()` add to or subtract from a counter and
#'   return its new value. A missing key starts at `default`. Counters hold
#'   whole numbers within ±2^53; a key holding anything else is a
#'   `dazcache_type_error`.
#'
#' @inheritParams cache_set
#' @param by The amount to add or subtract, a whole number.
#' @param default For `cache_pop()`, returned for a missing key; leave it out to
#'   make a missing key an error. For the counters, the starting value.
#'
#' @return `cache_add()` returns `TRUE` or `FALSE`. `cache_pop()` returns the
#'   value. `cache_touch()` returns the cache, invisibly. `cache_incr()` and
#'   `cache_decr()` return the new count, a double.
#'
#' @examples
#' s <- local_cache()
#' cache_add(s, "lock", Sys.getpid(), expire = 30)
#' cache_add(s, "lock", Sys.getpid())
#'
#' cache_incr(s, "hits")
#' cache_incr(s, "hits", by = 10)
#' cache_decr(s, "hits")
#'
#' cache_set(s, "job", "payload")
#' cache_pop(s, "job")
#' cache_has(s, "job")
#' @export
cache_add <- function(
  cache,
  key,
  value,
  ...,
  expire = NULL,
  tags = NULL,
  codec = NULL
) {
  check_supplied(c("key", "value"))
  rlang::check_dots_empty()
  check_writable(cache)
  entry <- cache_prepare(cache, key, value, expire, tags, codec)
  on.exit(unstage(list(entry)))
  engine_write(
    cache$engine,
    function(txn) {
      now <- unclass(Sys.time())
      if (!is.null(store_live_record(cache, txn, entry$key, now))) {
        return(FALSE)
      }
      store_put_entry(
        cache,
        txn,
        entry$key,
        entry$enc,
        now,
        expire = entry$expire,
        tags = entry$tags
      )
      store_cull_step(cache, txn, protect = entry$key$stored)
      TRUE
    },
    timeout = cache$timeout
  )
}

#' @rdname cache_add
#' @export
cache_pop <- function(cache, key, default) {
  check_supplied("key")
  check_writable(cache)
  key <- store_key(key)
  held <- NULL
  on.exit(if (!is.null(held)) unlink(held))
  hit <- engine_write(
    cache$engine,
    function(txn) {
      found <- store_read_entry(cache, txn, key)
      if (is.null(found)) {
        return(NULL)
      }
      # Before anything is deleted: an entry no codec here can read stays.
      record <- found$record
      codec_lookup(record$codec, record$codec_version, cache$codecs)
      if (!isTRUE(record$inline) && !identical(record$shape, "file")) {
        # The file may be reaped as soon as this commits, by this process or
        # another; the value is read from a second name for its bytes. (A file
        # entry's value is the path itself, so there is nothing to hold.)
        held <<- blob_hold(cache, found$path)
        found$path <- held
      }
      store_delete_entry(cache, txn, key$stored)
      found
    },
    timeout = cache$timeout
  )
  value <- if (!is.null(hit)) store_decode_entry(cache, hit, key)
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

#' @rdname cache_add
#' @export
cache_touch <- function(cache, key, expire) {
  check_supplied(c("key", "expire"))
  check_writable(cache)
  key <- store_key(key)
  deadline <- parse_expire(expire, unclass(Sys.time()))
  engine_write(
    cache$engine,
    function(txn) {
      old <- store_live_record(cache, txn, key)
      if (!is.null(old)) {
        record <- old
        record$expire <- deadline
        store_update_record(cache, txn, key$stored, old, record)
      }
    },
    timeout = cache$timeout
  )
  invisible(cache)
}

# Remove whatever staging files these prepared entries left: those whose blob
# was already stored, or whose transaction did not commit. A published file
# was renamed away and is not touched.
unstage <- function(entries) {
  for (entry in entries) {
    if (!is.null(entry$enc$blob)) blob_unlink(entry$enc$blob$staged)
  }
}
