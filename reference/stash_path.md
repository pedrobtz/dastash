# The file behind an entry

An entry of `inline_max` bytes or more, or one written with a
file-backed codec such as
[`codec_file()`](https://pedrobtz.github.io/dastash/reference/codec.md),
is stored as a file. `stash_path()` returns its path without reading it,
so other tools can read it in place.

The file is read-only, and identical content is one file however many
keys refer to it. The path is valid while the entry lives: deleting,
replacing or expiring the entry, from any process, may remove the file.
Copy the file if you need it to outlive the entry.

## Usage

``` r
stash_path(stash, key)
```

## Arguments

- stash:

  A stash, from
  [`stash()`](https://pedrobtz.github.io/dastash/reference/stash.md).

- key:

  A key.

## Value

The path, a string. A missing key is a `dastash_not_found` error, and an
entry stored inline a `dastash_type_error`.

## Examples

``` r
s <- local_stash()
stash_set(s, "numbers", runif(1e5))
#> Error in stash_set(s, "numbers", runif(1e+05)): This stash has been closed.
path <- stash_path(s, "numbers")
#> Error in stash_path(s, "numbers"): This stash has been closed.
file.size(path)
#> Error: object 'path' not found
identical(readRDS(path), stash_get(s, "numbers"))
#> Error: object 'path' not found
```
