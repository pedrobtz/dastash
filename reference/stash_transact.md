# Run several writes as one transaction

`code` runs with one write transaction open on the stash. Every write
inside it commits together when `code` finishes, or none does if it
raises an error, and reads inside it see its own writes. A nested
`stash_transact()` joins the outer one.

The transaction holds the stash's write lock for as long as `code` runs,
so other processes' writes wait: keep it short, and never compute a
value inside it that takes long to produce. It is also the fastest way
to write many entries, since the cost of making a write durable is paid
once.

Name the stash inside `code` as usual: there is no implicit one.

## Usage

``` r
stash_transact(stash, code)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- code:

  Code to run, in the calling environment.

## Value

The value of `code`.

## Examples

``` r
s <- local_stash()
stash_set(s, "balance", 100)
#> Error in stash_set(s, "balance", 100): This stash has been closed.
stash_transact(s, {
  stash_set(s, "balance", stash_get(s, "balance") - 30)
  stash_incr(s, "withdrawals")
})
#> Error in stash_transact(s, {    stash_set(s, "balance", stash_get(s, "balance") - 30)    stash_incr(s, "withdrawals")}): This stash has been closed.
stash_get(s, "balance")
#> Error in stash_get(s, "balance"): This stash has been closed.

# An error undoes the whole block.
try(stash_transact(s, {
  stash_set(s, "balance", 0)
  stop("changed my mind")
}))
#> Error in stash_transact(s, { : This stash has been closed.
stash_get(s, "balance")
#> Error in stash_get(s, "balance"): This stash has been closed.
```
