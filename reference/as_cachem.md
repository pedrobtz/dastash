# Use a stash through the cachem interface

Returns an object with the methods of a 'cachem' cache —
[`get()`](https://rdrr.io/r/base/get.html), `set()`,
[`exists()`](https://rdrr.io/r/base/exists.html),
[`remove()`](https://rdrr.io/r/base/rm.html), `reset()`, `keys()`,
`prune()`, `size()` and `info()` — so code written for 'cachem', such as
[`memoise::memoise()`](https://memoise.r-lib.org/reference/memoise.html)
and Shiny's `bindCache()`, can store in a stash. Keys follow 'cachem”s
rule, lower-case letters, digits, `_` and `-`, and are stored under
`prefix`.

## Usage

``` r
as_cachem(stash, ..., prefix = "cachem/", expire = NULL, codec = NULL)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- ...:

  Must be empty.

- prefix:

  Where in the stash the keys live.

- expire, codec:

  Passed to
  [`stash_set()`](https://pedrobtz.github.io/dastash/reference/stash_set.md)
  on every `set()`.

## Value

A list of functions with class `c("dastash_cachem", "cachem")`.

## Examples

``` r
s <- local_stash()
cache <- as_cachem(s)
#> Error in as_cachem(s): This stash has been closed.
cache$set("answer", 42)
#> Error: object 'cache' not found
cache$get("answer")
#> Error: object 'cache' not found
cache$keys()
#> Error: object 'cache' not found

slow_double <- function(x) x * 2
fast_double <- memoise::memoise(slow_double, cache = cache)
#> Error: object 'cache' not found
fast_double(21)
#> Error in fast_double(21): could not find function "fast_double"
```
