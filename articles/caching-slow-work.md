# Caching slow work

Most code that wants a cache has the same shape: a function that is
slow, called again with arguments it has seen before, by more than one
session. This article walks through that case, from a function that
calls a web service to the files it downloads.

``` r

library(dastash)
dir <- file.path(tempdir(), "slow-work")
s <- stash(dir)
```

## A slow function

Here is a stand-in for a call to a web service: it takes a moment, and
its answer depends only on its arguments. `calls` counts how often it
really runs.

``` r

calls <- 0
fetch_rates <- function(base, date) {
  calls <<- calls + 1
  Sys.sleep(0.5)
  set.seed(as.integer(date))
  data.frame(
    currency = c("EUR", "USD", "JPY"),
    rate = round(runif(3, 0.5, 150), 4)
  )
}
```

[`stash_memoise()`](https://pedrobtz.github.io/dastash/reference/stash_memoise.md)
wraps it. Rates for a past date do not change, but give them a day’s
expiry anyway, and a tag to drop them all by:

``` r

rates <- stash_memoise(
  fetch_rates,
  s,
  expire = as.difftime(1, units = "days"),
  tags = "rates"
)

system.time(rates("CHF", as.Date("2026-10-30")))
#>    user  system elapsed 
#>   0.004   0.000   0.534
system.time(rates("CHF", as.Date("2026-10-30")))
#>    user  system elapsed 
#>   0.001   0.001   0.001
calls
#> [1] 1
```

The second call is read from the stash. Each call is one entry, under a
key made from the function’s name and its arguments:

``` r

rates("CHF", as.Date("2026-10-29"))
#>   currency    rate
#> 1      EUR 40.4205
#> 2      USD  7.2563
#> 3      JPY  2.1548
stash_keys(s, prefix = "fetch_rates/")
#> [1] "fetch_rates/v1/{base=s:CHF,date=d:2026-10-29}"
#> [2] "fetch_rates/v1/{base=s:CHF,date=d:2026-10-30}"
```

## Results outlive the session

The entries are on disk, not in this session. Close the stash, open it
again, and memoise the function again under the same name, as a new
session or a scheduled job would: the answers are already there.

``` r

stash_close(s)
s <- stash(dir)
rates <- stash_memoise(fetch_rates, s, name = "fetch_rates")

rates("CHF", as.Date("2026-10-30"))
#>   currency     rate
#> 1      EUR  19.6596
#> 2      USD  32.5869
#> 3      JPY 149.9198
calls
#> [1] 2
```

Every process on the machine that opens `dir` shares them the same way:
a Shiny app and a nightly job that fills it, or parallel workers that
each compute part of the work and read what the others computed.

## When the answers change

There are three ways to throw results away, from narrow to wide.

``` r

# One call.
stash_forget(rates, "CHF", as.Date("2026-10-30"))

# Everything tagged when it was stored.
stash_evict(s, tag = "rates")
stash_keys(s, prefix = "fetch_rates/")
#> character(0)
```

When the function itself changes meaning, a new `version` gives it new
keys. The old entries are no longer read, and leave as they expire or as
the size limit evicts them.

``` r

rates <- stash_memoise(fetch_rates, s, name = "fetch_rates", version = 2)
stash_memoise_key(rates, "CHF", as.Date("2026-10-30"))
#> [1] "fetch_rates/v2/{base=s:CHF,date=d:2026-10-30}"
```

## Files you download

Some slow work produces a file: a download, an export from another tool.
[`codec_file()`](https://pedrobtz.github.io/dastash/reference/codec.md)
stores the file itself, and reading the entry gives a path to a
read-only copy that every process shares.

``` r

download <- function(url) {
  # A stand-in for utils::download.file(url, path).
  path <- tempfile(fileext = ".csv")
  utils::write.csv(mtcars, path, row.names = FALSE)
  path
}

cached_download <- function(s, url) {
  path <- stash_get(s, url, default = NULL)
  if (is.null(path)) {
    tmp <- download(url)
    stash_set(s, url, tmp, codec = codec_file(), expire = 7 * 24 * 3600)
    unlink(tmp)
    path <- stash_get(s, url)
  }
  path
}

path <- cached_download(s, "https://example.org/mtcars.csv")
basename(path)
#> [1] "450a97ba6b438c6ea5bdf2aaac7eab0ecbbf812b5ff74b56f62dcf0a0c7eb0e5.csv"
nrow(utils::read.csv(path))
#> [1] 32
```

The file keeps its extension, so tools that go by it read it as they
would the original.

## Code written for cachem

Packages that take a cachem cache, such as memoise and Shiny’s
`bindCache()`, can store in a stash through
[`as_cachem()`](https://pedrobtz.github.io/dastash/reference/as_cachem.md):

``` r

cache <- as_cachem(s)
slow_square <- function(x) {
  Sys.sleep(0.5)
  x^2
}
fast_square <- memoise::memoise(slow_square, cache = cache)

system.time(fast_square(12))
#>    user  system elapsed 
#>   0.002   0.000   0.502
system.time(fast_square(12))
#>    user  system elapsed 
#>   0.010   0.000   0.011
```

``` r

stash_close(s)
unlink(dir, recursive = TRUE)
```
