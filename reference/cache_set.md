# Write to a cache

`cache_set()` stores a value under a key, replacing any entry there.
`cache_mset()` stores every element of a named list, in one transaction.
`cache_delete()` removes the entries for the keys given, in one
transaction; keys with no entry are ignored.

All three return the cache invisibly, so they chain with `|>`.

## Usage

``` r
cache_set(cache, key, value, ..., expire = NULL, tags = NULL, codec = NULL)

cache_mset(cache, values, ..., expire = NULL, tags = NULL, codec = NULL)

cache_delete(cache, keys)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- key:

  A key.

- value:

  The value to store.

- ...:

  Must be empty.

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

- values:

  A named list: each name is a key, each element its value.

- keys:

  A character vector of keys, or a list of keys.

## Value

The cache, invisibly.

## Examples

``` r
s <- local_cache()
s |>
  cache_set("a", 1) |>
  cache_mset(list(b = "two", c = 3:5))
#> Error in cache_set(s, "a", 1): This cache has been closed.
cache_keys(s)
#> Error in cache_keys(s): This cache has been closed.
cache_delete(s, c("a", "b"))
#> Error in cache_delete(s, c("a", "b")): This cache has been closed.
cache_keys(s)
#> Error in cache_keys(s): This cache has been closed.
```
