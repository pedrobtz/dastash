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
