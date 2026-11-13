# Keys

Every function that takes a `key` accepts a string, a `dazcache_key`, or
any value the canonical encoding covers. `cache_key()` builds a key from
values; `cache_key_chr()` returns the canonical text a key is stored
under, and `cache_key_hash()` its SHA-256.

A single string is its own text: `"XSWX/2026-08-29"` is stored under
exactly those bytes. Anything else — numbers, dates, vectors, lists,
data frames, or several values — is written in a specified text encoding
in which field order does not matter, `1L` and `1` agree, and a
timestamp's time zone is not part of its identity. A string that begins
like an encoded value (`{`, `(`, `~`, `#`, `D{`, or a type tag such as
`s:`) is escaped so the two can never collide.

Functions, environments, connections, S4 objects and external pointers
have no encoding and raise `dazcache_key_invalid`.

[`cache_keys()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md)
lists keys as their text. A plain string key's text is the string itself
and can be passed back as it is, but a structured key's text, such as
`"{n=i:1}"`, would be taken as a string. `cache_key_text()` turns a
listed text back into the key it lists.

## Usage

``` r
cache_key(...)

cache_key_chr(key)

cache_key_text(text)

cache_key_hash(key)
```

## Arguments

- ...:

  Values that make up the key: one unnamed value, or several values that
  are either all named or all unnamed. Named values are ordered by name,
  so their order does not matter. Supports `!!!` to splice a list.

- key:

  A string, a `dazcache_key`, or a value the encoding covers.

- text:

  One key's text, as
  [`cache_keys()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md)
  or `cache_key_chr()` gives it.

## Value

`cache_key()` and `cache_key_text()` return a `dazcache_key`.
`cache_key_chr()` returns the canonical text as a string, and
`cache_key_hash()` the SHA-256 of that text as 64 lower-case hex
characters.

## Examples

``` r
cache_key("XSWX/2026-08-29")
#> <dazcache_key> XSWX/2026-08-29

k <- cache_key(exchange = "XSWX", date = as.Date("2026-08-29"))
k
#> <dazcache_key> {date=d:2026-08-29,exchange=s:XSWX}
identical(k, cache_key(date = as.Date("2026-08-29"), exchange = "XSWX"))
#> [1] TRUE

cache_key_chr(list(n = 1L, p = 0.1))
#> [1] "{n=i:1,p=f:0x1.999999999999ap-4}"
cache_key_hash("XSWX/2026-08-29")
#> [1] "71700ef4036aa32ab0243e79eb67d400c264b1ea37e3c8cbdfc3ad129261e1cb"

# A listed structured key, used again.
s <- local_cache()
cache_set(s, list(n = 1), "one")
#> Error in cache_set(s, list(n = 1), "one"): This cache has been closed.
listed <- cache_keys(s)
#> Error in cache_keys(s): This cache has been closed.
listed
#> Error: object 'listed' not found
cache_get(s, cache_key_text(listed))
#> Error in cache_get(s, cache_key_text(listed)): This cache has been closed.
```
