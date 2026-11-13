# Run several writes as one transaction

`code` runs with one write transaction open on the cache. Every write
inside it commits together when `code` finishes, or none does if it
raises an error or is interrupted, and reads inside it see its own
writes. Leaving `code` early with
[`return()`](https://rdrr.io/r/base/function.html),
[`break`](https://rdrr.io/r/base/Control.html) or
[`next`](https://rdrr.io/r/base/Control.html) is finishing it: the
writes commit. A nested `cache_transact()` joins the outer one.

The transaction holds the cache's write lock for as long as `code` runs,
so other processes' writes wait: keep it short, and never compute a
value inside it that takes long to produce. It is also the fastest way
to write many entries, since the cost of making a write durable is paid
once.

If the process is killed while `code` runs, nothing it wrote is kept. On
macOS, and every platform but Linux and Windows, its lock is not
released either: see "Details" in
[`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

Name the cache inside `code` as usual: there is no implicit one.

## Usage

``` r
cache_transact(cache, code)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- code:

  Code to run, in the calling environment.

## Value

The value of `code`.

## Examples

``` r
s <- local_cache()
cache_set(s, "balance", 100)
#> Error in cache_set(s, "balance", 100): This cache has been closed.
cache_transact(s, {
  cache_set(s, "balance", cache_get(s, "balance") - 30)
  cache_incr(s, "withdrawals")
})
#> Error in cache_transact(s, {    cache_set(s, "balance", cache_get(s, "balance") - 30)    cache_incr(s, "withdrawals")}): This cache has been closed.
cache_get(s, "balance")
#> Error in cache_get(s, "balance"): This cache has been closed.

# An error undoes the whole block.
try(cache_transact(s, {
  cache_set(s, "balance", 0)
  stop("changed my mind")
}))
#> Error in cache_transact(s, { : This cache has been closed.
cache_get(s, "balance")
#> Error in cache_get(s, "balance"): This cache has been closed.
```
