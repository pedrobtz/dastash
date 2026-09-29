# Transactions (design.md §3.7). The block runs inside one write transaction
# on the stash's environment; every verb in it, on any handle to the same
# directory, joins that transaction (D21), and everything commits or aborts
# together.

#' Run several writes as one transaction
#'
#' @description
#' `code` runs with one write transaction open on the stash. Every write inside
#' it commits together when `code` finishes, or none does if it raises an error,
#' and reads inside it see its own writes. A nested `stash_transact()` joins the
#' outer one.
#'
#' The transaction holds the stash's write lock for as long as `code` runs, so
#' other processes' writes wait: keep it short, and never compute a value
#' inside it that takes long to produce. It is also the fastest way to write
#' many entries, since the cost of making a write durable is paid once.
#'
#' Name the stash inside `code` as usual: there is no implicit one.
#'
#' @inheritParams stash_get
#' @param code Code to run, in the calling environment.
#'
#' @return The value of `code`.
#'
#' @examples
#' s <- local_stash()
#' stash_set(s, "balance", 100)
#' stash_transact(s, {
#'   stash_set(s, "balance", stash_get(s, "balance") - 30)
#'   stash_incr(s, "withdrawals")
#' })
#' stash_get(s, "balance")
#'
#' # An error undoes the whole block.
#' try(stash_transact(s, {
#'   stash_set(s, "balance", 0)
#'   stop("changed my mind")
#' }))
#' stash_get(s, "balance")
#' @export
stash_transact <- function(stash, code) {
  check_writable(stash)
  engine_write(stash$engine, function(txn) code, timeout = stash$timeout)
}
