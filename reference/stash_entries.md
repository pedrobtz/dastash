# The catalogue of a stash

`stash_entries()` returns one row per live entry. `prefix` and `tag`
select entries through the stash's indexes; filter the rest with
ordinary data frame tools. `stash_info()` returns the row for one key,
or `NULL`.

`stash_stats()` returns one row describing the whole stash.

## Usage

``` r
stash_entries(stash, ..., prefix = NULL, tag = NULL, n = Inf)

stash_info(stash, key)

stash_stats(stash)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- ...:

  Must be empty.

- prefix:

  Only keys whose text begins with this string.

- tag:

  Only entries carrying this tag.

- n:

  The most keys to return.

- key:

  A key.

## Value

`stash_entries()` and `stash_info()` return a data frame with columns
`key`, `bytes`, `codec`, `inline`, `blob`, `tags` (a list of character
vectors), `shape`, `stored`, `accessed`, `hits` and `expires` (`NA` for
never). In this release `accessed` is always `stored` and `hits` always
0: reads are not yet recorded. `stash_stats()` returns a one-row data
frame with `count`, `bytes_inline`, `bytes_blob`, `volume`,
`size_limit`, `evictions`, `expired`, `eviction`, `durability`,
`format_version` and `key_encoding_version`.

## Examples

``` r
s <- local_stash()
stash_set(s, "a", 1:10, tags = "small")
#> Error in stash_set(s, "a", 1:10, tags = "small"): This stash has been closed.
stash_set(s, "b", "text", expire = 3600)
#> Error in stash_set(s, "b", "text", expire = 3600): This stash has been closed.
stash_entries(s)
#> Error in stash_entries(s): This stash has been closed.
stash_entries(s, tag = "small")
#> Error in stash_entries(s, tag = "small"): This stash has been closed.
stash_info(s, "b")
#> Error in stash_info(s, "b"): This stash has been closed.
stash_stats(s)
#> Error in stash_stats(s): This stash has been closed.
```
