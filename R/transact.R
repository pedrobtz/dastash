# Transactions (design.md §3.7). The block runs inside one write transaction
# on the cache's environment; every verb in it, on any handle to the same
# directory, joins that transaction (D21), and everything commits or aborts
# together.

#' Run several writes as one transaction
#'
#' @description
#' `code` runs with one write transaction open on the cache. Every write inside
#' it commits together when `code` finishes, or none does if it raises an error
#' or is interrupted, and reads inside it see its own writes. Leaving `code`
#' early with `return()`, `break` or `next` is finishing it: the writes commit.
#' A nested `cache_transact()` joins the outer one.
#'
#' The transaction holds the cache's write lock for as long as `code` runs, so
#' other processes' writes wait: keep it short, and never compute a value
#' inside it that takes long to produce. It is also the fastest way to write
#' many entries, since the cost of making a write durable is paid once.
#'
#' If the process is killed while `code` runs, nothing it wrote is kept. On
#' macOS, and every platform but Linux and Windows, its lock is not released
#' either: see "Details" in [cache()].
#'
#' Name the cache inside `code` as usual: there is no implicit one.
#'
#' @inheritParams cache_get
#' @param code Code to run, in the calling environment.
#'
#' @return The value of `code`.
#'
#' @examples
#' s <- local_cache()
#' cache_set(s, "balance", 100)
#' cache_transact(s, {
#'   cache_set(s, "balance", cache_get(s, "balance") - 30)
#'   cache_incr(s, "withdrawals")
#' })
#' cache_get(s, "balance")
#'
#' # An error undoes the whole block.
#' try(cache_transact(s, {
#'   cache_set(s, "balance", 0)
#'   stop("changed my mind")
#' }))
#' cache_get(s, "balance")
#' @export
cache_transact <- function(cache, code) {
  check_supplied("code")
  check_writable(cache)
  engine_write(cache$engine, function(txn) code, timeout = cache$timeout)
}
