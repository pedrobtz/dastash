# Read from a stash

`stash_get()` returns the value stored under a key. A missing key is an
error of class `dastash_not_found` unless `default` is supplied, in
which case `default` is returned; a stored `NULL` is a value like any
other.

`stash_mget()` reads several keys at once and returns a named list in
the order asked. `stash_has()` says which keys have an entry.

A key is a string, a key from
[`stash_key()`](https://pedrobtz.github.io/dastash/reference/stash_key.md),
or any value that can be a key; see
[`stash_key()`](https://pedrobtz.github.io/dastash/reference/stash_key.md).

## Usage

``` r
stash_get(stash, key, default)

stash_mget(stash, keys, default)

stash_has(stash, keys)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- key:

  A key.

- default:

  Returned for a missing key. Leave it out to make a missing key an
  error.

- keys:

  A character vector of keys, or a list of keys.

## Value

`stash_get()` returns the value. `stash_mget()` returns a list named by
each key's text. `stash_has()` returns a logical vector, one element per
key.

## Examples

``` r
s <- local_stash()
stash_set(s, "a", 1)
#> Error in stash_set(s, "a", 1): This stash has been closed.
stash_get(s, "a")
#> Error in stash_get(s, "a"): This stash has been closed.
stash_get(s, "b", default = NA)
#> Error in stash_get(s, "b", default = NA): This stash has been closed.
try(stash_get(s, "b"))
#> Error in stash_get(s, "b") : This stash has been closed.

stash_has(s, c("a", "b"))
#> Error in stash_has(s, c("a", "b")): This stash has been closed.
stash_mget(s, c("a", "b"), default = NULL)
#> Error in stash_mget(s, c("a", "b"), default = NULL): This stash has been closed.
```
