# Codecs

A codec turns a value into a file and back. The cache records which
codec wrote each entry and always decodes with that one, so changing the
default never makes stored entries unreadable.

- `codec_auto()`, the default, stores a raw vector or a single string as
  its bytes (`codec_raw()`) and everything else with `codec_rds()`. It
  never picks a codec that loses information or needs a suggested
  package.

- `codec_rds()` stores an R object with
  [`serialize()`](https://rdrr.io/r/base/serialize.html), losslessly,
  with the exceptions
  [`serialize()`](https://rdrr.io/r/base/serialize.html) has: an
  external pointer comes back null and a connection as a number that no
  longer refers to it. It refuses either as the value itself; one inside
  a list or an environment is stored, dead.

- `codec_raw()` stores a raw vector, or a single string as its UTF-8
  bytes, exactly as they are.

- `codec_file()` stores a copy of an existing file; reading the entry
  back gives the path of the stored copy, which is read-only. Always
  file-backed.

- `codec()` defines your own. Every process that reads its entries must
  pass it to
  [`cache()`](https://pedrobtz.github.io/dazcache/reference/cache.md) in
  `codecs`.

## Usage

``` r
codec(
  name,
  encode,
  decode,
  ...,
  ext = NULL,
  version = 1L,
  supports = NULL,
  always_file = FALSE
)

codec_auto()

codec_rds(compress = FALSE)

codec_raw()

codec_file()
```

## Arguments

- name:

  A name for the codec, not one of the built-in names. An entry records
  only this name, so a cache refuses a second, different codec under a
  name it already knows: give a changed codec a new name or `version`.

- encode:

  `function(value, path)`: write `value` to the file `path`. It may
  return a small named list, stored with the entry and passed back to
  `decode()`; anything else it returns is ignored. An element named
  exactly `ext` sets this value's file extension in place of the codec's
  `ext`, as `codec_file()` does to keep a file's own extension.

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

- always_file:

  `TRUE` to store every value as a file, however small. Needed when
  `decode()` returns `path` itself, or anything that reads it later: a
  small value is otherwise kept in the database and decoded from a
  temporary file that is gone when the value is returned.

- compress:

  Passed to [`saveRDS()`](https://rdrr.io/r/base/readRDS.html). Off by
  default: compression costs more time than a local disk saves. A cache
  created with `compress = TRUE` keeps it when reopened.

## Value

A codec: a list with class `dazcache_codec`.

## Examples

``` r
codec_auto()
#> <dazcache_codec> auto: raw for raw vectors and single strings, rds otherwise
codec_rds()
#> <dazcache_codec> rds v1 .rds

# A codec that stores a character vector as lines of text.
lines <- codec(
  "lines",
  encode = function(value, path) writeLines(value, path, useBytes = TRUE),
  decode = function(path, meta) readLines(path, encoding = "UTF-8"),
  ext = "txt",
  supports = function(value) is.character(value) && !anyNA(value)
)
lines
#> <dazcache_codec> lines v1 .txt
```
