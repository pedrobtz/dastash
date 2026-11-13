# Atomic writes

Each of these is one transaction, so it is atomic across processes:
eight processes calling `cache_incr()` on one key produce eight
increments.

- `cache_add()` writes only if the key has no entry, and returns whether
  it did. An expired entry counts as none.

- `cache_pop()` returns an entry's value and deletes it.

- `cache_touch()` gives an entry a new deadline without rewriting its
  value. It does nothing to a missing key.

- `cache_incr()` and `cache_decr()` add to or subtract from a counter
  and return its new value. A missing key starts at `default`. Counters
  hold whole numbers within ±2^53; a key holding anything else is a
  `dazcache_type_error`.

## Usage

``` r
cache_incr(cache, key, ..., by = 1, default = 0)

cache_decr(cache, key, ..., by = 1, default = 0)

cache_add(cache, key, value, ..., expire = NULL, tags = NULL, codec = NULL)

cache_pop(cache, key, default)

cache_touch(cache, key, expire)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- key:

  A key.

- ...:

  Must be empty.

- by:

  The amount to add or subtract, a whole number.

- default:

  For `cache_pop()`, returned for a missing key; leave it out to make a
  missing key an error. For the counters, the starting value.

- value:

  The value to store.

- expire:

  When the entry expires: `NULL` or `Inf` for never; a number of seconds
  from now (zero or less means already expired); a
  [difftime](https://rdrr.io/r/base/difftime.html) from now; or a
  [POSIXct](https://rdrr.io/r/base/DateTimeClasses.html) for an absolute
  time. An expired entry is absent to every read at once, and
  [`cache_expire()`](https://pedrobtz.github.io/dazcache/reference/cache_expire.md)
  reclaims its space.

- tags:

  A character vector of up to 16 tags, each at most 256 bytes, to group
  entries for
  [`cache_evict()`](https://pedrobtz.github.io/dazcache/reference/cache_cull.md)
  and
  [`cache_entries()`](https://pedrobtz.github.io/dazcache/reference/cache_entries.md).

- codec:

  The codec to write with, or `NULL` for the cache's default. See
  [`codec()`](https://pedrobtz.github.io/dazcache/reference/codec.md).

## Value

`cache_add()` returns `TRUE` or `FALSE`. `cache_pop()` returns the
value. `cache_touch()` returns the cache, invisibly. `cache_incr()` and
`cache_decr()` return the new count, a double.

## Examples

``` r
s <- local_cache()
cache_add(s, "lock", Sys.getpid(), expire = 30)
#> Error in cache_add(s, "lock", Sys.getpid(), expire = 30): This cache has been closed.
cache_add(s, "lock", Sys.getpid())
#> Error in cache_add(s, "lock", Sys.getpid()): This cache has been closed.

cache_incr(s, "hits")
#> Error in cache_incr(s, "hits"): This cache has been closed.
cache_incr(s, "hits", by = 10)
#> Error in cache_incr(s, "hits", by = 10): This cache has been closed.
cache_decr(s, "hits")
#> Error in cache_decr(s, "hits"): This cache has been closed.

cache_set(s, "job", "payload")
#> Error in cache_set(s, "job", "payload"): This cache has been closed.
cache_pop(s, "job")
#> Error in cache_pop(s, "job"): This cache has been closed.
cache_has(s, "job")
#> Error in cache_has(s, "job"): This cache has been closed.
```
