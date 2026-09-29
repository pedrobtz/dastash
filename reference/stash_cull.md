# Keep a stash under its size limit

`stash_cull()` reclaims expired entries, then evicts the least recently
stored entries until what the entries hold is within `size_limit`, in
transactions of at most `cull_limit` entries. Every write already runs
one such step when the stash is over its limit, so the limit holds
without a background process; `stash_cull()` finishes the job at once.

`stash_evict()` deletes every entry carrying a tag, or every entry whose
key begins with a prefix. `stash_clear()` deletes everything.

The limit counts the bytes entries hold, inline and in files. The
database file itself keeps the pages it frees for reuse rather than
shrinking, so
[`stash_volume()`](https://pedrobtz.github.io/dastash/reference/stash_keys.md),
which reports bytes on disk, can stay above the limit.

## Usage

``` r
stash_cull(stash)

stash_evict(stash, ..., tag = NULL, prefix = NULL)

stash_clear(stash)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- ...:

  Must be empty.

- tag:

  Delete every entry carrying this tag.

- prefix:

  Delete every entry whose key begins with this string.

## Value

The stash, invisibly.

## Examples

``` r
s <- local_stash(size_limit = 1e5, inline_max = 1000)
for (i in 1:20) stash_set(s, paste0("k", i), runif(1000))
#> Error in stash_set(s, paste0("k", i), runif(1000)): This stash has been closed.
stash_count(s)
#> Error in stash_count(s): This stash has been closed.
stash_cull(s)
#> Error in stash_cull(s): This stash has been closed.
stash_count(s)
#> Error in stash_count(s): This stash has been closed.

stash_set(s, "a", 1, tags = "group")
#> Error in stash_set(s, "a", 1, tags = "group"): This stash has been closed.
stash_set(s, "b", 2, tags = c("group", "other"))
#> Error in stash_set(s, "b", 2, tags = c("group", "other")): This stash has been closed.
stash_evict(s, tag = "group")
#> Error in stash_evict(s, tag = "group"): This stash has been closed.
stash_has(s, c("a", "b"))
#> Error in stash_has(s, c("a", "b")): This stash has been closed.

stash_clear(s)
#> Error in stash_clear(s): This stash has been closed.
stash_count(s)
#> Error in stash_count(s): This stash has been closed.
```
