# The catalogue of a cache

`cache_entries()` returns one row per live entry. `prefix` and `tag`
select entries through the cache's indexes; filter the rest with
ordinary data frame tools. `cache_info()` returns the row for one key,
or `NULL`.

`cache_stats()` returns one row describing the whole cache.

## Usage

``` r
cache_entries(cache, ..., prefix = NULL, tag = NULL, n = Inf)

cache_info(cache, key)

cache_stats(cache)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- ...:

  Must be empty.

- prefix:

  Only keys whose text begins with this string.

- tag:

  Only entries carrying this tag.

- n:

  The most keys to return.

- key:

  A key.

## Value

`cache_entries()` and `cache_info()` return a data frame with columns
`key`, `bytes`, `codec`, `inline`, `blob`, `tags` (a list of character
vectors), `shape`, `stored`, `accessed`, `hits` and `expires` (`NA` for
never). In this release `accessed` is always `stored` and `hits` always
0: reads are not yet recorded. `cache_stats()` returns a one-row data
frame with `count`, `bytes_inline`, `bytes_blob`, `volume`,
`size_limit`, `evictions`, `expired`, `eviction`, `durability`,
`format_version` and `key_encoding_version`.

## Examples

``` r
s <- local_cache()
cache_set(s, "a", 1:10, tags = "small")
#> Error in cache_set(s, "a", 1:10, tags = "small"): This cache has been closed.
cache_set(s, "b", "text", expire = 3600)
#> Error in cache_set(s, "b", "text", expire = 3600): This cache has been closed.
cache_entries(s)
#> Error in cache_entries(s): This cache has been closed.
cache_entries(s, tag = "small")
#> Error in cache_entries(s, tag = "small"): This cache has been closed.
cache_info(s, "b")
#> Error in cache_info(s, "b"): This cache has been closed.
cache_stats(s)
#> Error in cache_stats(s): This cache has been closed.
```
