# Open a cache

`cache()` opens the cache in directory `dir`, creating it if needed, and
returns a handle for the other `cache_*()` functions. Any number of R
processes on the machine can open the same directory at once; they share
it safely.

`local_cache()` opens a cache that closes when the calling function
returns, in a new temporary directory unless you give one, which is then
deleted. At the top level there is no function to return from, so
nothing closes it: call `cache_close()` yourself. `with_cache()` opens
one, passes it to a function, and closes it afterwards.

`cache_close()` closes a handle, `cache_is_open()` says whether it is
open, and `cache_dir()` returns its directory.

## Usage

``` r
cache(
  dir,
  ...,
  size_limit = 1024^3,
  eviction = c("least-recently-stored", "least-recently-used", "least-frequently-used",
    "none"),
  inline_max = 32 * 1024,
  codec = codec_auto(),
  codecs = list(),
  durability = c("safe", "fast", "unsafe"),
  map_size = 1024^3,
  cull_limit = 10L,
  timeout = 60,
  readonly = FALSE,
  create = TRUE
)

cache_close(cache)

cache_is_open(cache)

cache_dir(cache)

local_cache(dir = NULL, ..., .local_envir = parent.frame())

with_cache(dir, fn, ...)
```

## Arguments

- dir:

  The cache's directory.

- ...:

  Must be empty.

- size_limit:

  The size, in bytes, the cache is kept under. `Inf` for no limit.
  Stored with the cache.

- eviction:

  Which entries make room when the cache is over `size_limit`: the least
  recently stored, or `"none"` to never evict. Stored with the cache.
  `"least-recently-used"` and `"least-frequently-used"` are not yet
  available.

- inline_max:

  Values smaller than this many bytes are kept inside the database;
  larger ones become files. Stored with the cache.

- codec:

  The default codec for writes; see
  [`codec()`](https://pedrobtz.github.io/dazcache/reference/codec.md).
  Stored with the cache, by name.

- codecs:

  A list of your own codecs, made with
  [`codec()`](https://pedrobtz.github.io/dazcache/reference/codec.md),
  that this handle can read and write.

- durability:

  `"safe"` makes every write durable before it returns. `"fast"` does
  not wait for the disk: a crash may lose recent writes but never
  damages the cache. `"unsafe"` can damage it in a crash. The first
  process to open a cache sets this for everyone who opens it while it
  is open.

- map_size:

  The most the database file may grow to, in bytes: a whole number of at
  least 256 KiB (`2^18`).

- cull_limit:

  How many entries one eviction step removes at most, up to
  `.Machine$integer.max`.

- timeout:

  How long, in seconds, a write waits for another process's write to
  finish before raising `dazcache_busy`. `Inf` waits for as long as it
  takes.

- readonly:

  Open for reading only.

- create:

  Create the directory and the cache if they do not exist.

- cache:

  A cache, from `cache()`.

- .local_envir:

  The environment whose exit closes the cache.

- fn:

  A function of one argument, the open cache.

## Value

`cache()` and `local_cache()` return a `dazcache_cache`. `with_cache()`
returns what `fn` returns. `cache_close()` returns the cache, invisibly;
`cache_is_open()` `TRUE` or `FALSE`; and `cache_dir()` the cache's
directory, normalised.

## Details

`size_limit`, `eviction`, `inline_max` and `codec` belong to the store
and are fixed when it is created: a later `cache()` that passes a
*different* value raises `dazcache_config_conflict`, and one that leaves
them out uses the stored values. The other settings belong to this
handle only.

A second `cache()` on a directory this process already has open shares
the same underlying database; each handle is closed separately. While a
read-only handle is open, the same process cannot open the directory for
writing: close it first. A handle that is dropped without being closed
releases its share when it is garbage-collected; `cache_close()`
releases it at once.

A handle cannot be used from a forked child process, such as a
[`parallel::mclapply()`](https://rdrr.io/r/parallel/mclapply.html)
worker; open the cache inside the worker instead, which works whether or
not the parent has it open.

Opening a cache that exists only reads it, so it never waits for another
process's write. Writes take the cache's one write lock in turn, waiting
up to `timeout` seconds. On Linux and Windows the lock of a process
killed while writing is released at once. On macOS and other platforms
it is not: every later write raises `dazcache_busy` until every process
with the cache open has closed it, after which the next to open it
recovers the lock. Reads are not affected.

## Examples

``` r
dir <- tempfile("cache-")
s <- cache(dir)
cache_set(s, "greeting", "hello")
cache_get(s, "greeting")
#> [1] "hello"
cache_close(s)
unlink(dir, recursive = TRUE)

f <- function() {
  s <- local_cache()
  cache_set(s, "n", 1:3)
  cache_get(s, "n")
}
f()
#> [1] 1 2 3
```
