# Base generics for a stash

`length(s)` is
[`stash_count()`](https://pedrobtz.github.io/dastash/reference/stash_keys.md);
`s[[key]]` is
[`stash_get()`](https://pedrobtz.github.io/dastash/reference/stash_get.md),
an error on a miss; `s[[key]] <- value` is
[`stash_set()`](https://pedrobtz.github.io/dastash/reference/stash_set.md);
`as.list(s)` reads every value, warning above 1000 entries and refusing
above 100,000. [`names()`](https://rdrr.io/r/base/names.html), `[` and
`$` are not provided: listing is
[`stash_keys()`](https://pedrobtz.github.io/dastash/reference/stash_keys.md),
and a subset of a cache is not a cache.

## Usage

``` r
# S3 method for class 'dastash_stash'
length(x)

# S3 method for class 'dastash_stash'
x[[i, ...]]

# S3 method for class 'dastash_stash'
x[[i, ...]] <- value

# S3 method for class 'dastash_stash'
as.list(x, ...)
```

## Arguments

- x:

  A stash.

- i:

  A key.

- ...:

  Must be empty.

- value:

  The value to store.

## Value

[`length()`](https://rdrr.io/r/base/length.html) an integer; `[[` the
value; `[[<-` the stash; [`as.list()`](https://rdrr.io/r/base/list.html)
a named list.

## Examples

``` r
s <- local_stash()
s[["a"]] <- 1
#> Error in stash_set(x, i, value): This stash has been closed.
s[["a"]]
#> Error in stash_get(x, i): This stash has been closed.
length(s)
#> Error in stash_count(x): This stash has been closed.
as.list(s)
#> Error in stash_keys(x): This stash has been closed.
```
