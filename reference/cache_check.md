# Check a cache, and repair it

Compares every index, reference count and counter with what the entries
imply, and every stored file with its records. Returns one row per
problem found. With `repair = TRUE` it fixes them, in one transaction:
rebuilding index rows, recounting, removing entries whose file is gone
or damaged, and deleting files and staging leftovers nothing refers to.

A crash leaves at most unreferenced files; `cache_check(repair = TRUE)`
is how they are reclaimed. `hash = TRUE` also reads every stored file
and checks its bytes against its name, which is slow on a large cache.

## Usage

``` r
cache_check(cache, ..., repair = FALSE, hash = FALSE)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

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
s <- local_cache()
cache_set(s, "a", runif(1e4))
#> Error in cache_set(s, "a", runif(10000)): This cache has been closed.
cache_check(s)
#> Error in cache_check(s): This cache has been closed.
```
