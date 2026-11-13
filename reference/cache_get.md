# Read from a cache

`cache_get()` returns the value stored under a key. A missing key is an
error of class `dazcache_not_found` unless `default` is supplied, in
which case `default` is returned; a stored `NULL` is a value like any
other.

`cache_mget()` reads several keys at once and returns a named list in
the order asked. `cache_has()` says which keys have an entry.

A key is a string, a key from
[`cache_key()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md),
or any value that can be a key; see
[`cache_key()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md).

## Usage

``` r
cache_get(cache, key, default)

cache_mget(cache, keys, default)

cache_has(cache, keys)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- key:

  A key.

- default:

  Returned for a missing key. Leave it out to make a missing key an
  error.

- keys:

  A character vector of keys, or a list of keys.

## Value

`cache_get()` returns the value. `cache_mget()` returns a list named by
each key's text. `cache_has()` returns a logical vector, one element per
key.

## Examples

``` r
s <- local_cache()
cache_set(s, "a", 1)
#> Error in cache_set(s, "a", 1): This cache has been closed.
cache_get(s, "a")
#> Error in cache_get(s, "a"): This cache has been closed.
cache_get(s, "b", default = NA)
#> Error in cache_get(s, "b", default = NA): This cache has been closed.
try(cache_get(s, "b"))
#> Error in cache_get(s, "b") : This cache has been closed.

cache_has(s, c("a", "b"))
#> Error in cache_has(s, c("a", "b")): This cache has been closed.
cache_mget(s, c("a", "b"), default = NULL)
#> Error in cache_mget(s, c("a", "b"), default = NULL): This cache has been closed.
```
