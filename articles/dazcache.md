# Getting started with dazcache

dazcache keeps R values on disk, under keys, for as long as you want
them and no longer. A cache is a directory: open it, read and write it,
and every R process on the machine that opens the same directory sees
the same entries.

``` r

library(dazcache)

dir <- file.path(tempdir(), "getting-started")
s <- cache(dir)
s
#> <dazcache_cache> /tmp/RtmpFUnZfe/getting-started
#>   entries 0 · eviction least-recently-stored · durability safe
```

## Reading and writing

[`cache_set()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md)
stores a value under a key and returns the cache, so writes chain.
[`cache_get()`](https://pedrobtz.github.io/dazcache/reference/cache_get.md)
reads it back.

``` r

s |>
  cache_set("greeting", "hello") |>
  cache_set("numbers", 1:10)

cache_get(s, "numbers")
#>  [1]  1  2  3  4  5  6  7  8  9 10
```

A key with no entry is an error, unless you supply a `default`. A stored
`NULL` is a value like any other, so the two never get confused.

``` r

try(cache_get(s, "absent"))
#> Error in cache_get(s, "absent") : No entry for key "absent".
#> ℹ Supply `default` to return a value instead of erroring.
cache_get(s, "absent", default = NA)
#> [1] NA
cache_has(s, c("greeting", "absent"))
#> [1]  TRUE FALSE
```

[`cache_mget()`](https://pedrobtz.github.io/dazcache/reference/cache_get.md)
and
[`cache_mset()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md)
read and write several entries at once, and
[`cache_delete()`](https://pedrobtz.github.io/dazcache/reference/cache_set.md)
removes entries.

``` r

cache_mset(s, list(a = 1, b = 2))
cache_mget(s, c("a", "b"))
#> $a
#> [1] 1
#> 
#> $b
#> [1] 2
cache_delete(s, c("a", "b"))
```

## Keys

A string is its own key, so a `"group/item"` convention gives you
prefixes to list by:

``` r

cache_set(s, "prices/XSWX", 101.2)
cache_set(s, "prices/XNYS", 57.8)
cache_keys(s, prefix = "prices/")
#> [1] "prices/XNYS" "prices/XSWX"
```

A key can also be a number, a date, a vector or a named list. It is
written in a fixed text encoding: names are sorted, `1L` and `1` agree,
and a time zone is not part of a time’s identity, so the same values
always find the same entry.

``` r

cache_set(s, list(exchange = "XSWX", date = as.Date("2026-08-29")), "quotes")
cache_get(s, list(date = as.Date("2026-08-29"), exchange = "XSWX"))
#> [1] "quotes"
cache_key_chr(list(exchange = "XSWX", date = as.Date("2026-08-29")))
#> [1] "{date=d:2026-08-29,exchange=s:XSWX}"
```

## Expiry and tags

An entry can expire: after a number of seconds, a `difftime`, or at a
`POSIXct` time. An expired entry is gone for every reader at once.

``` r

cache_set(s, "session-token", "abc123", expire = as.difftime(30, units = "mins"))
cache_set(s, "stale", 1, expire = 0)
cache_has(s, "stale")
#> [1] FALSE
```

Tags group entries for invalidation. Tag everything derived from one
source, and drop it all when that source changes:

``` r

cache_set(s, "report/q3", "...", tags = "ledger")
cache_set(s, "report/q4", "...", tags = "ledger")
cache_evict(s, tag = "ledger")
cache_keys(s, prefix = "report/")
#> character(0)
```

## Memoising a function

[`cache_memoise()`](https://pedrobtz.github.io/dazcache/reference/cache_memoise.md)
wraps a function so that each call is looked up first and computed only
on a miss. The results outlive the session, and every process using the
cache shares them.

``` r

slow_mean <- function(n, seed = 1) {
  Sys.sleep(0.5)
  set.seed(seed)
  mean(rnorm(n))
}
fast_mean <- cache_memoise(slow_mean, s)

system.time(fast_mean(1e5))
#>    user  system elapsed 
#>   0.005   0.000   0.505
system.time(fast_mean(1e5))
#>    user  system elapsed 
#>   0.001   0.000   0.001
```

A call is keyed on the function’s name and its arguments, with defaults
filled in, so `fast_mean(1e5)` and `fast_mean(1e5, seed = 1)` are the
same entry. The key does not depend on the function’s code: when its
meaning changes, pass a new `version`.

``` r

cache_memoise_key(fast_mean, 1e5)
#> [1] "slow_mean/v1/{n=i:100000,seed=i:1}"
cache_forget(fast_mean, 1e5)
```

## Large values

Values of `inline_max` bytes (32 KiB) or more are stored as read-only
files, named by the hash of their content, so identical values are
stored once.
[`cache_path()`](https://pedrobtz.github.io/dazcache/reference/cache_path.md)
gives the file, for tools that read it in place.

![A small value lives inside its record in cache.mdbx; a large one
becomes a file in blobs/ that the record points at.](storage.svg)

A small value lives inside its record in `cache.mdbx`; a large one
becomes a file in `blobs/` that the record points at.

The cache’s directory holds the database, its lock file, the files and a
staging area:

``` text
getting-started/
├── cache.mdbx        every record and index
├── cache.mdbx-lck    the lock that coordinates processes
├── blobs/b7/b795…3745.rds
└── tmp/              files being written, before they are published
```

``` r

big <- runif(1e5)
cache_set(s, "big", big)
path <- cache_path(s, "big")
file.size(path)
#> [1] 800031
identical(readRDS(path), big)
#> [1] TRUE
```

## Looking inside

``` r

cache_entries(s)[, c("key", "bytes", "inline", "expires")]
#>                                   key  bytes inline             expires
#> 1                                 big 800031  FALSE                <NA>
#> 2                            greeting      5   TRUE                <NA>
#> 3                             numbers    133   TRUE                <NA>
#> 4                         prices/XNYS     39   TRUE                <NA>
#> 5                         prices/XSWX     39   TRUE                <NA>
#> 6                       session-token      6   TRUE 2026-11-13 22:08:02
#> 7 {date=d:2026-08-29,exchange=s:XSWX}      6   TRUE                <NA>
cache_stats(s)[, c("count", "bytes_inline", "bytes_blob", "volume")]
#>   count bytes_inline bytes_blob  volume
#> 1     8          267     800031 1062175
```

``` r

cache_close(s)
unlink(dir, recursive = TRUE)
```
