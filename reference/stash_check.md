# Check a stash, and repair it

Compares every index, reference count and counter with what the entries
imply, and every stored file with its records. Returns one row per
problem found. With `repair = TRUE` it fixes them, in one transaction:
rebuilding index rows, recounting, removing entries whose file is gone
or damaged, and deleting files and staging leftovers nothing refers to.

A crash leaves at most unreferenced files; `stash_check(repair = TRUE)`
is how they are reclaimed. `hash = TRUE` also reads every stored file
and checks its bytes against its name, which is slow on a large stash.

## Usage

``` r
stash_check(stash, ..., repair = FALSE, hash = FALSE)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- ...:

  Must be empty.

- repair:

  Fix what is found.

- hash:

  Verify the content of every stored file.

## Value

A data frame with columns `kind`, `key`, `path`, `detail` and
`repaired`, one row per finding. The kinds are `index_orphan`,
`index_missing`, `value_orphan`, `value_missing`, `blob_missing`,
`blob_orphan`, `blob_corrupt`, `refcount_drift`, `counter_drift`,
`tmp_stale` and `reader_stale`.

## Examples

``` r
s <- local_stash()
stash_set(s, "a", runif(1e4))
#> Error in stash_set(s, "a", runif(10000)): This stash has been closed.
stash_check(s)
#> Error in stash_check(s): This stash has been closed.
```
