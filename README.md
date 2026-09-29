
# dastash

<!-- badges: start -->

[![R-CMD-check](https://github.com/pedrobtz/dastash/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/pedrobtz/dastash/actions/workflows/R-CMD-check.yaml)
[![coverage](https://raw.githubusercontent.com/pedrobtz/dastash/main/.github/badges/coverage.svg)](https://github.com/pedrobtz/dastash/actions/workflows/coverage.yaml)
<!-- badges: end -->

dastash is a persistent disk cache that every R process on a machine can
share, in the style of Python’s
[diskcache](https://github.com/grantjenks/python-diskcache). Keys map to
values that outlive the session, expire on a clock, carry tags for bulk
invalidation, and are evicted when the cache grows past a size limit.
Small values live in a transactional
[libmdbx](https://libmdbx.dqdkfa.ru/) database, through the
[mdbx](https://github.com/pedrobtz/mdbx) package; larger ones become
read-only files named by their content, stored once however many keys
hold them.

## Installation

``` r
install.packages("dastash")
```

The development version is on GitHub:

``` r
# install.packages("pak")
pak::pak("pedrobtz/dastash")
```

## A tour

``` r
library(dastash)

s <- stash(file.path(tempdir(), "prices"))

# Keys map to values, with expiry and tags.
s |> stash_set("XSWX/2026-08-29", c(101.2, 101.9), expire = 3600, tags = "XSWX")
stash_get(s, "XSWX/2026-08-29")
#> [1] 101.2 101.9
stash_get(s, "missing", default = NULL)
#> NULL

# A key can be any combination of values; field order does not matter.
stash_set(s, list(exchange = "XSWX", date = as.Date("2026-08-29")), "quotes")
stash_get(s, list(date = as.Date("2026-08-29"), exchange = "XSWX"))
#> [1] "quotes"

# A function, cached across sessions and processes.
slow_square <- function(x) {
  Sys.sleep(1)
  x^2
}
square <- stash_memoise(slow_square, s)
system.time(square(12))
#>    user  system elapsed 
#>   0.003   0.000   1.034
system.time(square(12))
#>    user  system elapsed 
#>   0.000   0.000   0.001

# The catalogue is a data frame.
stash_entries(s)[, c("key", "bytes", "codec", "expires")]
#>                                   key bytes codec             expires
#> 1                     XSWX/2026-08-29    47   rds 2026-09-29 19:59:14
#> 2             slow_square/v1/{x=i:12}    39   rds                <NA>
#> 3 {date=d:2026-08-29,exchange=s:XSWX}     6   raw                <NA>

stash_close(s)
```

## Where it works

Many R processes on **one machine**, over a **local filesystem**:
interactive sessions, scheduled jobs and parallel workers can use one
stash at once. Reads never wait; writes take turns. A stash on a network
filesystem (NFS, SMB, cloud file shares) is not supported, because its
locks cannot be relied on.

A stash cannot be carried into a forked child such as a
`parallel::mclapply()` worker: open it inside the worker.

## Learn more

- [Getting
  started](https://pedrobtz.github.io/dastash/articles/dastash.html)
- [Operating a shared
  stash](https://pedrobtz.github.io/dastash/articles/shared-stash.html)
- [Reference](https://pedrobtz.github.io/dastash/reference/)
