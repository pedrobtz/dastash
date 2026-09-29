# Reclaim expired entries

An expired entry is already absent to every read; `stash_expire()`
removes it and frees its space. It walks entries from the earliest
deadline, in transactions of at most `cull_limit` entries (see
[`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md)), so
it never holds the write lock for long. It can be run at any time, by
any process: it cannot change what a read returns.

## Usage

``` r
stash_expire(stash, ..., n = Inf)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- ...:

  Must be empty.

- n:

  The most entries to remove.

## Value

The stash, invisibly.

## Examples

``` r
s <- local_stash()
stash_set(s, "brief", 1, expire = 0)
#> Error in stash_set(s, "brief", 1, expire = 0): This stash has been closed.
stash_count(s)
#> Error in stash_count(s): This stash has been closed.
stash_expire(s)
#> Error in stash_expire(s): This stash has been closed.
stash_count(s)
#> Error in stash_count(s): This stash has been closed.
```
