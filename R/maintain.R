# Maintenance (design.md §3.6, §9.1). Every verb here is one operation — drop
# the entries a predicate selects — over the index that answers the predicate
# in order, walked from its cheap end in bounded transactions.

#' Reclaim expired entries
#'
#' An expired entry is already absent to every read; `stash_expire()` removes it
#' and frees its space. It walks entries from the earliest deadline, in
#' transactions of at most `cull_limit` entries (see [stash()]), so it never
#' holds the write lock for long. It can be run at any time, by any process:
#' it cannot change what a read returns.
#'
#' @inheritParams stash_get
#' @param ... Must be empty.
#' @param n The most entries to remove.
#'
#' @return The stash, invisibly.
#'
#' @examples
#' s <- local_stash()
#' stash_set(s, "brief", 1, expire = 0)
#' stash_count(s)
#' stash_expire(s)
#' stash_count(s)
#' @export
stash_expire <- function(stash, ..., n = Inf) {
  rlang::check_dots_empty()
  check_writable(stash)
  check_number(n, "n", rlang::current_env(), min = 0, whole = TRUE, allow_inf = TRUE)
  removed <- 0
  while (removed < n) {
    batch <- min(stash$cull_limit, n - removed)
    done <- engine_write(stash$engine, function(txn) {
      store_expire_batch(stash, txn, batch, unclass(Sys.time()))
    }, timeout = stash$timeout)
    removed <- removed + done
    if (done < batch) break
  }
  invisible(stash)
}

# Delete up to `n` entries whose deadline has passed, earliest first, in the
# open transaction. Returns how many.
store_expire_batch <- function(s, txn, n, now) {
  rows <- engine_scan(txn, engine_db(s$engine, "expiry"), n = n)
  done <- 0
  for (row in rows) {
    parts <- index_key_parts(row)
    if (parts$value > now) break
    store_delete_entry(s, txn, parts$stored)
    done <- done + 1
  }
  if (done > 0) {
    store_counters_add(txn, list(expired = done))
  }
  done
}

#' Keep a stash under its size limit
#'
#' @description
#' `stash_cull()` reclaims expired entries, then evicts the least recently
#' stored entries until what the entries hold is within `size_limit`, in
#' transactions of at most `cull_limit` entries. Every write already runs one
#' such step when the stash is over its limit, so the limit holds without a
#' background process; `stash_cull()` finishes the job at once.
#'
#' `stash_evict()` deletes every entry carrying a tag, or every entry whose key
#' begins with a prefix. `stash_clear()` deletes everything.
#'
#' The limit counts the bytes entries hold, inline and in files. The database
#' file itself keeps the pages it frees for reuse rather than shrinking, so
#' [stash_volume()], which reports bytes on disk, can stay above the limit.
#'
#' @inheritParams stash_expire
#' @param tag Delete every entry carrying this tag.
#' @param prefix Delete every entry whose key begins with this string.
#'
#' @return The stash, invisibly.
#'
#' @examples
#' s <- local_stash(size_limit = 1e5, inline_max = 1000)
#' for (i in 1:20) stash_set(s, paste0("k", i), runif(1000))
#' stash_count(s)
#' stash_cull(s)
#' stash_count(s)
#'
#' stash_set(s, "a", 1, tags = "group")
#' stash_set(s, "b", 2, tags = c("group", "other"))
#' stash_evict(s, tag = "group")
#' stash_has(s, c("a", "b"))
#'
#' stash_clear(s)
#' stash_count(s)
#' @export
stash_cull <- function(stash) {
  check_writable(stash)
  stash_expire(stash)
  limit <- stash$config$size_limit
  if (is.null(eviction_index(stash$config$eviction)) || !is.finite(limit)) {
    return(invisible(stash))
  }
  repeat {
    done <- engine_write(stash$engine, function(txn) {
      store_evict_batch(stash, txn, stash$cull_limit, limit)
    }, timeout = stash$timeout)
    if (done < stash$cull_limit) break
  }
  invisible(stash)
}

#' @rdname stash_cull
#' @export
stash_evict <- function(stash, ..., tag = NULL, prefix = NULL) {
  rlang::check_dots_empty()
  check_writable(stash)
  if (is.null(tag) == is.null(prefix)) {
    abort_type_error("Give exactly one of `tag` and `prefix`.")
  }
  if (!is.null(tag)) {
    check_string(tag, "tag", rlang::current_env())
    tag <- utf8_text(tag)
  } else {
    check_string_or_empty(prefix, "prefix")
  }
  e <- stash$engine
  chunk <- 1000L
  repeat {
    done <- engine_write(e, function(txn) {
      stored <- if (!is.null(tag)) {
        rows <- engine_scan(txn, engine_db(e, "tags"), prefix = c(charToRaw(tag), as.raw(0L)), n = chunk)
        vapply(rows, tag_key_stored, character(1))
      } else {
        engine_scan(txn, engine_db(e, "meta"), prefix = prefix, n = chunk, as = "character")
      }
      for (k in stored) store_delete_entry(stash, txn, k)
      length(stored)
    }, timeout = stash$timeout)
    if (done < chunk) break
  }
  invisible(stash)
}

#' @rdname stash_cull
#' @export
stash_clear <- function(stash) {
  check_writable(stash)
  e <- stash$engine
  engine_write(e, function(txn) {
    names <- engine_scan(txn, engine_db(e, "blobs"), as = "character")
    for (db in store_databases(stash$config)) engine_clear_db(txn, engine_db(e, db))
    counters <- store_counters(txn)
    counters$bytes_inline <- 0
    counters$bytes_blob <- 0
    engine_put(txn, NULL, "counters", record_encode(counters))
    if (length(names) > 0L) engine_defer(e, function() blob_reap(stash, names))
  }, timeout = stash$timeout)
  invisible(stash)
}

# The bytes the entries hold, which the size limit is about.
store_held_bytes <- function(txn) {
  counters <- store_counters(txn)
  counters$bytes_inline + counters$bytes_blob
}

# One bounded cull inside a write that took the stash over its limit: reclaim
# up to cull_limit expired entries, then evict up to cull_limit of the least
# recently stored, never the entries this write just stored.
store_cull_step <- function(s, txn, protect = character()) {
  limit <- s$config$size_limit
  if (!is.finite(limit) || store_held_bytes(txn) <= limit) {
    return(invisible(0))
  }
  store_expire_batch(s, txn, s$cull_limit, unclass(Sys.time()))
  store_evict_batch(s, txn, s$cull_limit, limit, protect)
}

# Evict up to `n` entries from the front of the eviction index while the stash
# holds more than `limit`. Returns how many.
store_evict_batch <- function(s, txn, n, limit, protect = character()) {
  index <- eviction_index(s$config$eviction)
  if (is.null(index) || store_held_bytes(txn) <= limit) {
    return(0)
  }
  rows <- engine_scan(txn, engine_db(s$engine, index), n = n + length(protect))
  done <- 0
  for (row in rows) {
    if (done >= n || store_held_bytes(txn) <= limit) break
    stored <- index_key_parts(row)$stored
    if (stored %in% protect) next
    store_delete_entry(s, txn, stored)
    done <- done + 1
  }
  if (done > 0) {
    store_counters_add(txn, list(evictions = done))
  }
  done
}
