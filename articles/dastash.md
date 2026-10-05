# Getting started with dastash

dastash keeps R values on disk, under keys, for as long as you want them
and no longer. A stash is a directory: open it, read and write it, and
every R process on the machine that opens the same directory sees the
same entries.

``` r

library(dastash)

dir <- file.path(tempdir(), "getting-started")
s <- stash(dir)
s
#> <dastash_stash> /tmp/RtmpyDsoIa/getting-started
#>   entries 0 · eviction least-recently-stored · durability safe
```

## Reading and writing

[`stash_set()`](https://pedrobtz.github.io/dastash/reference/stash_set.md)
stores a value under a key and returns the stash, so writes chain.
[`stash_get()`](https://pedrobtz.github.io/dastash/reference/stash_get.md)
reads it back.

``` r

s |>
  stash_set("greeting", "hello") |>
  stash_set("numbers", 1:10)

stash_get(s, "numbers")
#>  [1]  1  2  3  4  5  6  7  8  9 10
```

A key with no entry is an error, unless you supply a `default`. A stored
`NULL` is a value like any other, so the two never get confused.

``` r

try(stash_get(s, "absent"))
#> Error in stash_get(s, "absent") : No entry for key "absent".
#> ℹ Supply `default` to return a value instead of erroring.
stash_get(s, "absent", default = NA)
#> [1] NA
stash_has(s, c("greeting", "absent"))
#> [1]  TRUE FALSE
```

[`stash_mget()`](https://pedrobtz.github.io/dastash/reference/stash_get.md)
and
[`stash_mset()`](https://pedrobtz.github.io/dastash/reference/stash_set.md)
read and write several entries at once, and
[`stash_delete()`](https://pedrobtz.github.io/dastash/reference/stash_set.md)
removes entries.

``` r

stash_mset(s, list(a = 1, b = 2))
stash_mget(s, c("a", "b"))
#> $a
#> [1] 1
#> 
#> $b
#> [1] 2
stash_delete(s, c("a", "b"))
```

## Keys

A string is its own key, so a `"group/item"` convention gives you
prefixes to list by:

``` r

stash_set(s, "prices/XSWX", 101.2)
stash_set(s, "prices/XNYS", 57.8)
stash_keys(s, prefix = "prices/")
#> [1] "prices/XNYS" "prices/XSWX"
```

A key can also be a number, a date, a vector or a named list. It is
written in a fixed text encoding: names are sorted, `1L` and `1` agree,
and a time zone is not part of a time’s identity, so the same values
always find the same entry.

``` r

stash_set(s, list(exchange = "XSWX", date = as.Date("2026-08-29")), "quotes")
stash_get(s, list(date = as.Date("2026-08-29"), exchange = "XSWX"))
#> [1] "quotes"
stash_key_chr(list(exchange = "XSWX", date = as.Date("2026-08-29")))
#> [1] "{date=d:2026-08-29,exchange=s:XSWX}"
```

## Expiry and tags

An entry can expire: after a number of seconds, a `difftime`, or at a
`POSIXct` time. An expired entry is gone for every reader at once.

``` r

stash_set(s, "session-token", "abc123", expire = as.difftime(30, units = "mins"))
stash_set(s, "stale", 1, expire = 0)
stash_has(s, "stale")
#> [1] FALSE
```

Tags group entries for invalidation. Tag everything derived from one
source, and drop it all when that source changes:

``` r

stash_set(s, "report/q3", "...", tags = "ledger")
stash_set(s, "report/q4", "...", tags = "ledger")
stash_evict(s, tag = "ledger")
stash_keys(s, prefix = "report/")
#> character(0)
```

## Memoising a function

[`stash_memoise()`](https://pedrobtz.github.io/dastash/reference/stash_memoise.md)
wraps a function so that each call is looked up first and computed only
on a miss. The results outlive the session, and every process using the
stash shares them.

``` r

slow_mean <- function(n, seed = 1) {
  Sys.sleep(0.5)
  set.seed(seed)
  mean(rnorm(n))
}
fast_mean <- stash_memoise(slow_mean, s)

system.time(fast_mean(1e5))
#>    user  system elapsed 
#>   0.008   0.000   0.508
system.time(fast_mean(1e5))
#>    user  system elapsed 
#>   0.001   0.000   0.001
```

A call is keyed on the function’s name and its arguments, with defaults
filled in, so `fast_mean(1e5)` and `fast_mean(1e5, seed = 1)` are the
same entry. The key does not depend on the function’s code: when its
meaning changes, pass a new `version`.

``` r

stash_memoise_key(fast_mean, 1e5)
#> [1] "slow_mean/v1/{n=i:100000,seed=i:1}"
stash_forget(fast_mean, 1e5)
```

## Large values

Values of `inline_max` bytes (32 KiB) or more are stored as read-only
files, named by the hash of their content, so identical values are
stored once.
[`stash_path()`](https://pedrobtz.github.io/dastash/reference/stash_path.md)
gives the file, for tools that read it in place.

``` r

big <- runif(1e5)
stash_set(s, "big", big)
path <- stash_path(s, "big")
file.size(path)
#> [1] 800031
identical(readRDS(path), big)
#> [1] TRUE
```

## Looking inside

``` r

stash_entries(s)[, c("key", "bytes", "inline", "expires")]
#>                                   key  bytes inline             expires
#> 1                                 big 800031  FALSE                <NA>
#> 2                            greeting      5   TRUE                <NA>
#> 3                             numbers    133   TRUE                <NA>
#> 4                         prices/XNYS     39   TRUE                <NA>
#> 5                         prices/XSWX     39   TRUE                <NA>
#> 6                       session-token      6   TRUE 2026-10-05 13:12:15
#> 7 {date=d:2026-08-29,exchange=s:XSWX}      6   TRUE                <NA>
stash_stats(s)[, c("count", "bytes_inline", "bytes_blob", "volume")]
#>   count bytes_inline bytes_blob  volume
#> 1     8          267     800031 1062175
```

``` r

stash_close(s)
unlink(dir, recursive = TRUE)
```
