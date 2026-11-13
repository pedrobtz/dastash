# Base generics for a cache

`length(s)` is
[`cache_count()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md);
`s[[key]]` is
[`cache_get()`](https://pedrobtz.github.io/dazcache/reference/cache_get.md),
an error on a miss; `s[[key]] <- value` is
[`cache_set()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md);
`as.list(s)` reads every value, warning above 1000 entries and refusing
above 100,000. [`names()`](https://rdrr.io/r/base/names.html), `[` and
`$` are not provided: listing is
[`cache_keys()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md),
and a subset of a cache is not a cache.

## Usage

``` r
# S3 method for class 'dazcache_cache'
length(x)

# S3 method for class 'dazcache_cache'
x[[i, ...]]

# S3 method for class 'dazcache_cache'
x[[i, ...]] <- value

# S3 method for class 'dazcache_cache'
as.list(x, ...)
```

## Arguments

- x:

  A cache.

- i:

  A key.

- ...:

  Must be empty.

- value:

  The value to store.

## Value

[`length()`](https://rdrr.io/r/base/length.html) an integer; `[[` the
value; `[[<-` the cache; [`as.list()`](https://rdrr.io/r/base/list.html)
a named list.

## Examples

``` r
s <- local_cache()
s[["a"]] <- 1
#> Error in cache_set(x, i, value): This cache has been closed.
s[["a"]]
#> Error in cache_get(x, i): This cache has been closed.
length(s)
#> Error in cache_count(x): This cache has been closed.
as.list(s)
#> Error in cache_keys(x): This cache has been closed.
```
