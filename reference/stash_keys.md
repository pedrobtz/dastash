# List and count a stash's entries

`stash_keys()` returns keys in the order they are stored: the text of
each key, as
[`stash_key_chr()`](https://pedrobtz.github.io/dastash/reference/stash_key.md)
gives it. A structured key's text is not itself that key; pass it
through
[`stash_key_text()`](https://pedrobtz.github.io/dastash/reference/stash_key.md)
to use it again. Use `prefix` for keys that begin with a string, and
`start` with `n` to page through a large stash: `start` is inclusive, so
drop the first key of every page after the first.

A key of up to 512 bytes is stored as itself, so those keys come in byte
order. A longer key is stored under `#` and a digest of its text, and
sorts there, among keys beginning with `#`, in no meaningful order.
`prefix` still matches it by its text, which the stash keeps for keys up
to 4096 bytes; of a longer key it keeps the first 256 bytes, so a
`prefix` longer than that does not match it, and it is listed as its
digest.

`stash_count()` returns the number of entries, including expired ones
that
[`stash_expire()`](https://pedrobtz.github.io/dastash/reference/stash_expire.md)
has not reclaimed yet. `stash_volume()` returns the bytes the stash
occupies on disk: its database file and every stored file.

## Usage

``` r
stash_keys(stash, ..., prefix = NULL, start = NULL, n = Inf)

stash_count(stash)

stash_volume(stash)
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

`stash_keys()` returns a character vector, `stash_count()` an integer,
and `stash_volume()` a number of bytes.

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
