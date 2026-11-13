# Reclaim expired entries

An expired entry is already absent to every read; `cache_expire()`
removes it and frees its space. It walks entries from the earliest
deadline, in transactions of at most `cull_limit` entries (see
[`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md)), so
it never holds the write lock for long. It can be run at any time, by
any process: it cannot change what a read returns.

## Usage

``` r
cache_expire(cache, ..., n = Inf)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- ...:

  Must be empty.

- n:

  The most entries to remove.

## Value

The cache, invisibly.

## Examples

``` r
s <- local_cache()
cache_set(s, "brief", 1, expire = 0)
#> Error in cache_set(s, "brief", 1, expire = 0): This cache has been closed.
cache_count(s)
#> Error in cache_count(s): This cache has been closed.
cache_expire(s)
#> Error in cache_expire(s): This cache has been closed.
cache_count(s)
#> Error in cache_count(s): This cache has been closed.
```
