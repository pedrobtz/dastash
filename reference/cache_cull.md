# Keep a cache under its size limit

`cache_cull()` reclaims expired entries, then evicts the least recently
stored entries until what the entries hold is within `size_limit`, in
transactions of at most `cull_limit` entries. Every write already runs
one such step when the cache is over its limit, so the limit holds
without a background process; `cache_cull()` finishes the job at once.

`cache_evict()` deletes every entry carrying a tag, or every entry whose
key begins with a prefix. `cache_clear()` deletes everything.

The limit counts the bytes entries hold, inline and in files. The
database file itself keeps the pages it frees for reuse rather than
shrinking, so
[`cache_volume()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md),
which reports bytes on disk, can stay above the limit.

## Usage

``` r
cache_cull(cache)

cache_evict(cache, ..., tag = NULL, prefix = NULL)

cache_clear(cache)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- ...:

  Must be empty.

- tag:

  Delete every entry carrying this tag.

- prefix:

  Delete every entry whose key begins with this string.

## Value

The cache, invisibly.

## Examples

``` r
s <- local_cache(size_limit = 1e5, inline_max = 1000)
for (i in 1:20) cache_set(s, paste0("k", i), runif(1000))
#> Error in cache_set(s, paste0("k", i), runif(1000)): This cache has been closed.
cache_count(s)
#> Error in cache_count(s): This cache has been closed.
cache_cull(s)
#> Error in cache_cull(s): This cache has been closed.
cache_count(s)
#> Error in cache_count(s): This cache has been closed.

cache_set(s, "a", 1, tags = "group")
#> Error in cache_set(s, "a", 1, tags = "group"): This cache has been closed.
cache_set(s, "b", 2, tags = c("group", "other"))
#> Error in cache_set(s, "b", 2, tags = c("group", "other")): This cache has been closed.
cache_evict(s, tag = "group")
#> Error in cache_evict(s, tag = "group"): This cache has been closed.
cache_has(s, c("a", "b"))
#> Error in cache_has(s, c("a", "b")): This cache has been closed.

cache_clear(s)
#> Error in cache_clear(s): This cache has been closed.
cache_count(s)
#> Error in cache_count(s): This cache has been closed.
```
