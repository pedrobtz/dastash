# Codecs

A codec turns a value into a file and back. The stash records which
codec wrote each entry and always decodes with that one, so changing the
default never makes stored entries unreadable.

- `codec_auto()`, the default, stores a raw vector or a single string as
  its bytes (`codec_raw()`) and everything else with `codec_rds()`. It
  never picks a codec that loses information or needs a suggested
  package.

- `codec_rds()` stores any R object with
  [`serialize()`](https://rdrr.io/r/base/serialize.html), losslessly.

- `codec_raw()` stores a raw vector, or a single string as its UTF-8
  bytes, exactly as they are.

- `codec_file()` stores a copy of an existing file; reading the entry
  back gives the path of the stored copy, which is read-only. Always
  file-backed.

- `codec()` defines your own. Every process that reads its entries must
  pass it to `stash()` in `codecs`.

## Usage

``` r
codec(name, encode, decode, ..., ext = NULL, version = 1L, supports = NULL)

codec_auto()

codec_rds(compress = FALSE)

codec_raw()

codec_file()
```

## Arguments

- name:

  A name for the codec, not one of the built-in names.

- encode:

  `function(value, path)`: write `value` to the file `path`. It may
  return a small named list, stored with the entry and passed back to
  `decode()`; anything else it returns is ignored.

- decode:

  `function(path, meta)`: read the value back from `path`. `meta` is
  what `encode()` returned, or `NULL`.

- ...:

  Must be empty.

- ext:

  A file extension for the stored file, without the dot, or `NULL`.

- version:

  A whole number, raised when the encoding changes. An entry written by
  a newer version than the handle knows is refused.

- supports:

  `function(value)` returning `TRUE` for values the codec round-trips
  without loss, or `NULL` for every value.

- compress:

  Passed to [`saveRDS()`](https://rdrr.io/r/base/readRDS.html). Off by
  default: compression costs more time than a local disk saves.

## Value

A codec: a list with class `dastash_codec`.

## Examples

``` r
codec_auto()
#> <dastash_codec> auto: raw for raw vectors and single strings, rds otherwise
codec_rds()
#> <dastash_codec> rds v1 .rds

# A codec that stores a character vector as lines of text.
lines <- codec(
  "lines",
  encode = function(value, path) writeLines(value, path, useBytes = TRUE),
  decode = function(path, meta) readLines(path, encoding = "UTF-8"),
  ext = "txt",
  supports = function(value) is.character(value) && !anyNA(value)
)
lines
#> <dastash_codec> lines v1 .txt
```
