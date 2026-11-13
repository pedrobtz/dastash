# Maintenance (design.md §3.6, §9.1). Every verb here is one operation — drop
# the entries a predicate selects — over the index that answers the predicate
# in order, walked from its cheap end in bounded transactions.

#' Reclaim expired entries
#'
#' @description
#' An expired entry is already absent to every read; `cache_expire()` removes it
#' and frees its space. It walks entries from the earliest deadline, in
#' transactions of at most `cull_limit` entries (see [cache()]), so it never
#' holds the write lock for long. It can be run at any time, by any process:
#' it cannot change what a read returns.
#'
#' @inheritParams cache_get
#' @param ... Must be empty.
#' @param n The most entries to remove.
#'
#' @return The cache, invisibly.
#'
#' @examples
#' s <- local_cache()
#' cache_set(s, "brief", 1, expire = 0)
#' cache_count(s)
#' cache_expire(s)
#' cache_count(s)
#' @export
cache_expire <- function(cache, ..., n = Inf) {
  rlang::check_dots_empty()
  check_writable(cache)
  check_number(n, "n", min = 0, whole = TRUE, allow_inf = TRUE)
  removed <- 0
  while (removed < n) {
    batch <- min(cache$cull_limit, n - removed)
    done <- engine_write(
      cache$engine,
      function(txn) {
        store_expire_batch(cache, txn, batch, unclass(Sys.time()))
      },
      timeout = cache$timeout
    )
    removed <- removed + done
    if (done < batch) break
  }
  invisible(cache)
}

# Delete up to `n` entries whose deadline has passed, earliest first, in the
# open transaction. Returns how many.
store_expire_batch <- function(s, txn, n, now) {
  rows <- engine_scan(txn, engine_db(s$engine, "expiry"), n = n)
  done <- 0
  for (row in rows) {
    parts <- index_key_parts(row)
    if (parts$value > now) {
      break
    }
    store_delete_entry(s, txn, parts$stored)
    done <- done + 1
  }
  if (done > 0) {
    store_counters_add(txn, list(expired = done))
  }
  done
}

#' Keep a cache under its size limit
#'
#' @description
#' `cache_cull()` reclaims expired entries, then evicts the least recently
#' stored entries until what the entries hold is within `size_limit`, in
#' transactions of at most `cull_limit` entries. Every write already runs one
#' such step when the cache is over its limit, so the limit holds without a
#' background process; `cache_cull()` finishes the job at once.
#'
#' `cache_evict()` deletes every entry carrying a tag, or every entry whose key
#' begins with a prefix. `cache_clear()` deletes everything.
#'
#' The limit counts the bytes entries hold, inline and in files. The database
#' file itself keeps the pages it frees for reuse rather than shrinking, so
#' [cache_volume()], which reports bytes on disk, can stay above the limit.
#'
#' @inheritParams cache_expire
#' @param tag Delete every entry carrying this tag.
#' @param prefix Delete every entry whose key begins with this string.
#'
#' @return The cache, invisibly.
#'
#' @examples
#' s <- local_cache(size_limit = 1e5, inline_max = 1000)
#' for (i in 1:20) cache_set(s, paste0("k", i), runif(1000))
#' cache_count(s)
#' cache_cull(s)
#' cache_count(s)
#'
#' cache_set(s, "a", 1, tags = "group")
#' cache_set(s, "b", 2, tags = c("group", "other"))
#' cache_evict(s, tag = "group")
#' cache_has(s, c("a", "b"))
#'
#' cache_clear(s)
#' cache_count(s)
#' @export
cache_cull <- function(cache) {
  check_writable(cache)
  cache_expire(cache)
  limit <- cache$config$size_limit
  if (is.null(eviction_index(cache$config$eviction)) || !is.finite(limit)) {
    return(invisible(cache))
  }
  repeat {
    done <- engine_write(
      cache$engine,
      function(txn) {
        store_evict_batch(cache, txn, cache$cull_limit, limit)
      },
      timeout = cache$timeout
    )
    if (done < cache$cull_limit) break
  }
  invisible(cache)
}

#' @rdname cache_cull
#' @export
cache_evict <- function(cache, ..., tag = NULL, prefix = NULL) {
  rlang::check_dots_empty()
  check_writable(cache)
  if (is.null(tag) == is.null(prefix)) {
    abort_type_error("Give exactly one of `tag` and `prefix`.")
  }
  if (!is.null(tag)) {
    check_string(tag, "tag")
    tag <- utf8_text(tag)
  } else {
    check_string_or_empty(prefix, "prefix")
  }
  e <- cache$engine
  chunk <- ENGINE_SCAN_CHUNK
  repeat {
    done <- engine_write(
      e,
      function(txn) {
        if (is.null(tag)) {
          stored <- store_scan_prefix(cache, txn, prefix, n = chunk)$stored
          for (k in stored) {
            store_delete_entry(cache, txn, k)
          }
          return(length(stored))
        }
        tags_db <- engine_db(e, "tags")
        rows <- engine_scan(
          txn,
          tags_db,
          prefix = c(charToRaw(tag), as.raw(0L)),
          n = chunk
        )
        for (row in rows) {
          # A row whose entry is gone is damage; delete it too, or the walk would
          # find it at the front of every chunk and never end.
          if (!store_delete_entry(cache, txn, tag_key_stored(row))) {
            engine_del(txn, tags_db, row)
          }
        }
        length(rows)
      },
      timeout = cache$timeout
    )
    if (done < chunk) break
  }
  invisible(cache)
}

# Delete the entries under `prefix` whose key text `matches()` accepts: a
# namespace inside a prefix, such as a memoised function's versions, where a
# raw prefix would also take a user's key that merely extends it. Pages through
# the prefix in write transactions of ENGINE_SCAN_CHUNK, stepping past the
# keys it keeps. A digested key too long to keep is judged by its preview.
evict_prefix_where <- function(cache, prefix, matches) {
  e <- cache$engine
  chunk <- ENGINE_SCAN_CHUNK
  start <- NULL
  repeat {
    found <- engine_write(
      e,
      function(txn) {
        page <- store_scan_prefix(cache, txn, prefix, start = start, n = chunk)
        text <- vapply(
          seq_along(page$stored),
          function(i) {
            r <- page$records[[i]]
            if (record_digested(r)) {
              r$key_text %||% r$key_preview %||% ""
            } else {
              page$stored[[i]]
            }
          },
          character(1)
        )
        for (k in page$stored[matches(text)]) {
          store_delete_entry(cache, txn, k)
        }
        if (length(page$stored) > 0L) {
          start <<- page$stored[[length(page$stored)]]
        }
        length(page$stored)
      },
      timeout = cache$timeout
    )
    if (found < chunk) break
  }
  invisible(cache)
}

#' @rdname cache_cull
#' @export
cache_clear <- function(cache) {
  check_writable(cache)
  e <- cache$engine
  engine_write(
    e,
    function(txn) {
      blob_names <- engine_scan(txn, engine_db(e, "blobs"), as = "character")
      for (db in store_databases(cache$config)) {
        engine_clear_db(txn, engine_db(e, db))
      }
      counters <- store_counters(txn)
      counters$bytes_inline <- 0
      counters$bytes_blob <- 0
      engine_put(txn, NULL, "counters", record_encode(counters))
      if (length(blob_names) > 0L) blob_defer_reap(cache, blob_names)
    },
    timeout = cache$timeout
  )
  invisible(cache)
}

# The bytes the entries hold, which the size limit is about.
store_held_bytes <- function(txn) {
  counters <- store_counters(txn)
  counters$bytes_inline + counters$bytes_blob
}

# One bounded cull inside a write that took the cache over its limit: reclaim
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

# Evict up to `n` entries from the front of the eviction index while the cache
# holds more than `limit`. Returns how many.
store_evict_batch <- function(s, txn, n, limit, protect = character()) {
  index <- eviction_index(s$config$eviction)
  if (is.null(index) || store_held_bytes(txn) <= limit) {
    return(0)
  }
  rows <- engine_scan(txn, engine_db(s$engine, index), n = n + length(protect))
  done <- 0
  for (row in rows) {
    if (done >= n || store_held_bytes(txn) <= limit) {
      break
    }
    stored <- index_key_parts(row)$stored
    if (stored %in% protect) {
      next
    }
    store_delete_entry(s, txn, stored)
    done <- done + 1
  }
  if (done > 0) {
    store_counters_add(txn, list(evictions = done))
  }
  done
}
