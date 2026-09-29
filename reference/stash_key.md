# Keys

Every function that takes a `key` accepts a string, a `dastash_key`, or
any value the canonical encoding covers. `stash_key()` builds a key from
values; `stash_key_chr()` returns the canonical text a key is stored
under, and `stash_key_hash()` its SHA-256.

A single string is its own text: `"XSWX/2026-08-29"` is stored under
exactly those bytes. Anything else — numbers, dates, vectors, lists,
data frames, or several values — is written in a specified text encoding
in which field order does not matter, `1L` and `1` agree, and a
timestamp's time zone is not part of its identity. A string that begins
like an encoded value (`{`, `(`, `~`, `#`, `D{`, or a type tag such as
`s:`) is escaped so the two can never collide.

Functions, environments, connections, S4 objects and external pointers
have no encoding and raise `dastash_key_invalid`.

## Usage

``` r
stash_key(...)

stash_key_chr(key)

stash_key_hash(key)
```

## Arguments

- ...:

  Values that make up the key: one unnamed value, or several values that
  are either all named or all unnamed. Named values are ordered by name,
  so their order does not matter. Supports `!!!` to splice a list.

- key:

  A string, a `dastash_key`, or a value the encoding covers.

## Value

`stash_key()` returns a `dastash_key`. `stash_key_chr()` returns the
canonical text as a string, and `stash_key_hash()` the SHA-256 of that
text as 64 lower-case hex characters.

## Examples

``` r
stash_key("XSWX/2026-08-29")
#> <dastash_key> XSWX/2026-08-29

k <- stash_key(exchange = "XSWX", date = as.Date("2026-08-29"))
k
#> <dastash_key> {date=d:2026-08-29,exchange=s:XSWX}
identical(k, stash_key(date = as.Date("2026-08-29"), exchange = "XSWX"))
#> [1] TRUE

stash_key_chr(list(n = 1L, p = 0.1))
#> [1] "{n=i:1,p=f:0x1.999999999999ap-4}"
stash_key_hash("XSWX/2026-08-29")
#> [1] "71700ef4036aa32ab0243e79eb67d400c264b1ea37e3c8cbdfc3ad129261e1cb"
```
