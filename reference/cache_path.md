# The file behind an entry

An entry of `inline_max` bytes or more, or one written with a
file-backed codec such as
[`codec_file()`](https://pedrobtz.github.io/dazcache/reference/codec.md),
is stored as a file. `cache_path()` returns its path without reading it,
so other tools can read it in place.

The file is read-only, and identical content is one file however many
keys refer to it. The path is valid while the entry lives: deleting,
replacing or expiring the entry, from any process, may remove the file.
Copy the file if you need it to outlive the entry.

## Usage

``` r
cache_path(cache, key)
```

## Arguments

- cache:

  A cache, from
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md).

- key:

  A key.

## Value

The path, a string. A missing key is a `dazcache_not_found` error, and
an entry stored inline a `dazcache_type_error`.

## Examples

``` r
s <- local_cache()
cache_set(s, "numbers", runif(1e5))
#> Error in cache_set(s, "numbers", runif(1e+05)): This cache has been closed.
path <- cache_path(s, "numbers")
#> Error in cache_path(s, "numbers"): This cache has been closed.
file.size(path)
#> Error: object 'path' not found
identical(readRDS(path), cache_get(s, "numbers"))
#> Error: object 'path' not found
```
