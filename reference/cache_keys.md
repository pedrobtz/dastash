# List and count a cache's entries

`cache_keys()` returns keys in the order they are stored: the text of
each key, as
[`cache_key_chr()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md)
gives it. A structured key's text is not itself that key; pass it
through
[`cache_key_text()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md)
to use it again. Use `prefix` for keys that begin with a string, and
`start` with `n` to page through a large cache: `start` is inclusive, so
drop the first key of every page after the first.

A key of up to 512 bytes is stored as itself, so those keys come in byte
order. A longer key is stored under `#` and a digest of its text, and
sorts there, among keys beginning with `#`, in no meaningful order.
`prefix` still matches it by its text, which the cache keeps for keys up
to 4096 bytes; of a longer key it keeps the first 256 bytes, so a
`prefix` longer than that does not match it, and it is listed as its
digest.

`cache_count()` returns the number of entries, including expired ones
that
[`cache_expire()`](https://pedrobtz.github.io/dazcache/reference/cache_expire.md)
has not reclaimed yet. `cache_volume()` returns the bytes the cache
occupies on disk: its database file and every stored file.

## Usage

``` r
cache_keys(cache, ..., prefix = NULL, start = NULL, n = Inf)

cache_count(cache)

cache_volume(cache)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- ...:

  Must be empty.

- prefix:

  Only keys whose text begins with this string.

- start:

  Begin at this key, inclusive: a key's text as `cache_keys()` returns
  it, or a key from
  [`cache_key()`](https://pedrobtz.github.io/dazcache/reference/cache_key.md).

- n:

  The most keys to return.

## Value

`cache_keys()` returns a character vector, `cache_count()` an integer,
and `cache_volume()` a number of bytes.

## Examples

``` r
s <- local_cache()
for (k in c("prices/a", "prices/b", "volumes/a")) cache_set(s, k, 1)
#> Error in cache_set(s, k, 1): This cache has been closed.
cache_keys(s)
#> Error in cache_keys(s): This cache has been closed.
cache_keys(s, prefix = "prices/")
#> Error in cache_keys(s, prefix = "prices/"): This cache has been closed.
cache_keys(s, start = "prices/b", n = 2)
#> Error in cache_keys(s, start = "prices/b", n = 2): This cache has been closed.
cache_count(s)
#> Error in cache_count(s): This cache has been closed.
```
