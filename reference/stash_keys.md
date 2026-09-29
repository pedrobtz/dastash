# List and count a stash's entries

`stash_keys()` returns keys in key order: the text of each key, as
[`stash_key_chr()`](https://pedrobtz.github.io/dastash/reference/stash_key.md)
gives it. Use `prefix` for keys that begin with a string, and `start`
with `n` to page through a large stash: `start` is inclusive, so drop
the first key of every page after the first.

`stash_count()` returns the number of entries.

## Usage

``` r
stash_keys(stash, ..., prefix = NULL, start = NULL, n = Inf)

stash_count(stash)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- ...:

  Must be empty.

- prefix:

  Only keys whose text begins with this string.

- start:

  Begin at this key, inclusive.

- n:

  The most keys to return.

## Value

`stash_keys()` returns a character vector; `stash_count()` an integer.

## Examples

``` r
s <- local_stash()
for (k in c("prices/a", "prices/b", "volumes/a")) stash_set(s, k, 1)
#> Error in stash_set(s, k, 1): This stash has been closed.
stash_keys(s)
#> Error in stash_keys(s): This stash has been closed.
stash_keys(s, prefix = "prices/")
#> Error in stash_keys(s, prefix = "prices/"): This stash has been closed.
stash_keys(s, start = "prices/b", n = 2)
#> Error in stash_keys(s, start = "prices/b", n = 2): This stash has been closed.
stash_count(s)
#> Error in stash_count(s): This stash has been closed.
```
