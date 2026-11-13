# Use a cache through the cachem interface

Returns an object with the methods of a cachem cache —
[`get()`](https://rdrr.io/r/base/get.html), `set()`,
[`exists()`](https://rdrr.io/r/base/exists.html),
[`remove()`](https://rdrr.io/r/base/rm.html), `reset()`, `keys()`,
`prune()`, `size()` and `info()` — so code written for cachem, such as
[`memoise::memoise()`](https://memoise.r-lib.org/reference/memoise.html)
and Shiny's `bindCache()`, can store in a cache. Keys follow cachem's
rule, lower-case letters, digits, `_` and `-`, and are stored under
`prefix`.

## Usage

``` r
as_cachem(cache, ..., prefix = "cachem/", expire = NULL, codec = NULL)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- ...:

  Must be empty.

- prefix:

  Where in the cache the keys live. It must end with a character a
  cachem key cannot contain, such as `/`, so that two adapters never
  share keys; the adapter lists and resets only its own keys.

- expire, codec:

  Passed to
  [`cache_set()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md)
  on every `set()`.

## Value

A list of functions with class `c("dazcache_cachem", "cachem")`.

## Examples

``` r
s <- local_cache()
cache <- as_cachem(s)
#> Error in as_cachem(s): This cache has been closed.
cache$set("answer", 42)
#> Error in cache$set: object of type 'closure' is not subsettable
cache$get("answer")
#> Error in cache$get: object of type 'closure' is not subsettable
cache$keys()
#> Error in cache$keys: object of type 'closure' is not subsettable

slow_double <- function(x) x * 2
fast_double <- memoise::memoise(slow_double, cache = cache)
#> Error in x$digest: object of type 'closure' is not subsettable
fast_double(21)
#> Error in fast_double(21): could not find function "fast_double"
```
