# Write to a stash

`stash_set()` stores a value under a key, replacing any entry there.
`stash_mset()` stores every element of a named list, in one transaction.
`stash_delete()` removes the entries for the keys given, in one
transaction; keys with no entry are ignored.

All three return the stash invisibly, so they chain with `|>`.

## Usage

``` r
stash_set(stash, key, value, ..., expire = NULL, tags = NULL, codec = NULL)

stash_mset(stash, values, ..., expire = NULL, tags = NULL, codec = NULL)

stash_delete(stash, keys)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- key:

  A key.

- value:

  The value to store.

- ...:

  Must be empty.

- expire:

  Not yet supported: leave as `NULL`.

- tags:

  Not yet supported: leave as `NULL`.

- codec:

  The codec to write with, or `NULL` for the stash's default. See
  [`codec()`](https://pedrobtz.github.io/dastash/reference/codec.md).

- values:

  A named list: each name is a key, each element its value.

- keys:

  A character vector of keys, or a list of keys.

## Value

The stash, invisibly.

## Examples

``` r
s <- local_stash()
s |>
  stash_set("a", 1) |>
  stash_mset(list(b = "two", c = 3:5))
#> Error in stash_set(s, "a", 1): This stash has been closed.
stash_keys(s)
#> Error in stash_keys(s): This stash has been closed.
stash_delete(s, c("a", "b"))
#> Error in stash_delete(s, c("a", "b")): This stash has been closed.
stash_keys(s)
#> Error in stash_keys(s): This stash has been closed.
```
