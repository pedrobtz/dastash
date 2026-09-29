# Atomic writes

Each of these is one transaction, so it is atomic across processes:
eight processes calling `stash_incr()` on one key produce eight
increments.

- `stash_add()` writes only if the key has no entry, and returns whether
  it did. An expired entry counts as none.

- `stash_pop()` returns an entry's value and deletes it.

- `stash_touch()` gives an entry a new deadline without rewriting its
  value. It does nothing to a missing key.

- `stash_incr()` and `stash_decr()` add to or subtract from a counter
  and return its new value. A missing key starts at `default`. Counters
  hold whole numbers within ±2^53; a key holding anything else is a
  `dastash_type_error`.

## Usage

``` r
stash_incr(stash, key, ..., by = 1, default = 0)

stash_decr(stash, key, ..., by = 1, default = 0)

stash_add(stash, key, value, ..., expire = NULL, tags = NULL, codec = NULL)

stash_pop(stash, key, default)

stash_touch(stash, key, expire)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- key:

  A key.

- ...:

  Must be empty.

- by:

  The amount to add or subtract, a whole number.

- default:

  For `stash_pop()`, returned for a missing key; leave it out to make a
  missing key an error. For the counters, the starting value.

- value:

  The value to store.

- expire:

  When the entry expires: `NULL` or `Inf` for never; a number of seconds
  from now (zero or less means already expired); a
  [difftime](https://rdrr.io/r/base/difftime.html) from now; or a
  [POSIXct](https://rdrr.io/r/base/DateTimeClasses.html) for an absolute
  time. An expired entry is absent to every read at once, and
  [`stash_expire()`](https://pedrobtz.github.io/dastash/reference/stash_expire.md)
  reclaims its space.

- tags:

  A character vector of up to 16 tags, each at most 256 bytes, to group
  entries for
  [`stash_evict()`](https://pedrobtz.github.io/dastash/reference/stash_cull.md)
  and
  [`stash_entries()`](https://pedrobtz.github.io/dastash/reference/stash_entries.md).

- codec:

  The codec to write with, or `NULL` for the stash's default. See
  [`codec()`](https://pedrobtz.github.io/dastash/reference/codec.md).

## Value

`stash_add()` returns `TRUE` or `FALSE`. `stash_pop()` returns the
value. `stash_touch()` returns the stash, invisibly. `stash_incr()` and
`stash_decr()` return the new count, a double.

## Examples

``` r
s <- local_stash()
stash_add(s, "lock", Sys.getpid(), expire = 30)
#> Error in stash_add(s, "lock", Sys.getpid(), expire = 30): This stash has been closed.
stash_add(s, "lock", Sys.getpid())
#> Error in stash_add(s, "lock", Sys.getpid()): This stash has been closed.

stash_incr(s, "hits")
#> Error in stash_incr(s, "hits"): This stash has been closed.
stash_incr(s, "hits", by = 10)
#> Error in stash_incr(s, "hits", by = 10): This stash has been closed.
stash_decr(s, "hits")
#> Error in stash_decr(s, "hits"): This stash has been closed.

stash_set(s, "job", "payload")
#> Error in stash_set(s, "job", "payload"): This stash has been closed.
stash_pop(s, "job")
#> Error in stash_pop(s, "job"): This stash has been closed.
stash_has(s, "job")
#> Error in stash_has(s, "job"): This stash has been closed.
```
