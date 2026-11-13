# Memoise a function in a cache

`cache_memoise()` returns a function that looks each call up in the
cache first, and on a miss calls `f` and stores what it returns. The
cache outlives the session and is shared by every process using the
cache.

The key of a call is the function's `name`, `version` and its arguments,
matched to `f`'s formals with defaults filled in: `f(1)` and
`f(1, verbose = FALSE)` are one entry when `FALSE` is the default. It
does not depend on `f`'s code; change `version` when a change in meaning
should invalidate what is stored. An argument that cannot be part of a
key — a connection, an environment, a function — is an error at call
time: leave it out with `omit`, or supply `key`.

Two processes missing the same call at once both run `f`, and one result
is kept. That is duplicated work, never a wrong result.

If the cache cannot store a result because its write lock stayed busy,
it is full or it is read-only, the result is returned anyway, with a
warning of class `dazcache_memoise_unstored`. A codec that cannot store
it is an error.

A result stored as a file, with `codec = codec_file()`, is the path of
the cached file on a miss as on a hit, not the path `f` returned.

`cache_memoise_key()` returns the key a call would use, `cache_forget()`
deletes one call's entry, and `cache_forget_all()` every entry of the
function.

## Usage

``` r
cache_memoise(
  f,
  cache,
  ...,
  expire = NULL,
  tags = NULL,
  codec = NULL,
  key = NULL,
  omit = NULL,
  version = 1L,
  name = NULL
)

cache_memoise_key(f, ...)

cache_forget(f, ...)

cache_forget_all(f)

is_cache_memoised(f)
```

## Arguments

- f:

  A function.

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- ...:

  For `cache_memoise()`, must be empty. For the others, the arguments of
  a call to the memoised function.

- expire, tags, codec:

  Passed to
  [`cache_set()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md)
  when a result is stored.

- key:

  `NULL`, or a function of the list of matched arguments returning a
  key, to key calls on something else than every argument.

- omit:

  Names of arguments to leave out of the key.

- version:

  A whole number, part of every key.

- name:

  The function's name in its keys. Defaults to the name `f` was passed
  as; an anonymous function needs one.

## Value

`cache_memoise()` returns the memoised function. `cache_memoise_key()`
returns a key's text. `cache_forget()` and `cache_forget_all()` return
the memoised function, invisibly. `is_cache_memoised()` returns `TRUE`
or `FALSE`.

## Examples

``` r
s <- local_cache()
slow_square <- function(x, verbose = FALSE) {
  Sys.sleep(0.1)
  x^2
}
fast_square <- cache_memoise(slow_square, s)
#> Error in cache_memoise(slow_square, s): This cache has been closed.
fast_square(4)
#> Error in fast_square(4): could not find function "fast_square"
fast_square(4)
#> Error in fast_square(4): could not find function "fast_square"
cache_memoise_key(fast_square, 4)
#> Error: object 'fast_square' not found
cache_forget(fast_square, 4)
#> Error: object 'fast_square' not found

# Keep an argument out of the key.
fit <- cache_memoise(
  function(data_id, verbose = FALSE) data_id * 2,
  s,
  name = "fit",
  omit = "verbose"
)
#> Error in cache_memoise(function(data_id, verbose = FALSE) data_id * 2,     s, name = "fit", omit = "verbose"): This cache has been closed.
identical(cache_memoise_key(fit, 1), cache_memoise_key(fit, 1, verbose = TRUE))
#> Error: object 'fit' not found
```
