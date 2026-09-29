# Open a stash

`stash()` opens the cache in directory `dir`, creating it if needed, and
returns a handle for the other `stash_*()` functions. Any number of R
processes on the machine can open the same directory at once; they share
it safely.

`local_stash()` opens a stash that closes when the calling function
returns, in a new temporary directory unless you give one, which is then
deleted. `with_stash()` opens one, passes it to a function, and closes
it afterwards.

## Usage

``` r
stash(
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

stash_close(stash)

stash_is_open(stash)

stash_dir(stash)

local_stash(dir = NULL, ..., .local_envir = parent.frame())

with_stash(dir, fn, ...)
```

## Arguments

- dir:

  The stash's directory.

- ...:

  Must be empty.

- size_limit:

  The size, in bytes, the stash is kept under. `Inf` for no limit.
  Stored with the stash.

- eviction:

  Which entries make room when the stash is over `size_limit`: the least
  recently stored, or `"none"` to never evict. Stored with the stash.
  `"least-recently-used"` and `"least-frequently-used"` are not yet
  available.

- inline_max:

  Values smaller than this many bytes are kept inside the database;
  larger ones become files. Stored with the stash.

- codec:

  The default codec for writes; see
  [`codec()`](https://pedrobtz.github.io/dastash/reference/codec.md).
  Stored with the stash, by name.

- codecs:

  A list of your own codecs, made with
  [`codec()`](https://pedrobtz.github.io/dastash/reference/codec.md),
  that this handle can read and write.

- durability:

  `"safe"` makes every write durable before it returns. `"fast"` does
  not wait for the disk: a crash may lose recent writes but never
  damages the stash. `"unsafe"` can damage it in a crash. The first
  process to open a stash sets this for everyone who opens it while it
  is open.

- map_size:

  The most the database file may grow to, in bytes.

- cull_limit:

  How many entries one eviction step removes at most.

- timeout:

  How long, in seconds, a write waits for another process's write to
  finish before raising `dastash_busy`.

- readonly:

  Open for reading only.

- create:

  Create the directory and the stash if they do not exist.

- stash:

  A stash, from `stash()`.

- .local_envir:

  The environment whose exit closes the stash.

- fn:

  A function of one argument, the open stash.

## Value

`stash()` and `local_stash()` return a `dastash_stash`. `with_stash()`
returns what `fn` returns.

## Details

`size_limit`, `eviction`, `inline_max` and `codec` belong to the store
and are fixed when it is created: a later `stash()` that passes a
*different* value raises `dastash_config_conflict`, and one that leaves
them out uses the stored values. The other settings belong to this
handle only.

A second `stash()` on a directory this process already has open shares
the same underlying database; each handle is closed separately. While a
read-only handle is open, the same process cannot open the directory for
writing: close it first.

A handle cannot be used from a forked child process, such as a
[`parallel::mclapply()`](https://rdrr.io/r/parallel/mclapply.html)
worker; open the stash inside the worker instead.

## Examples

``` r
dir <- tempfile("stash-")
s <- stash(dir)
stash_set(s, "greeting", "hello")
stash_get(s, "greeting")
#> [1] "hello"
stash_close(s)
unlink(dir, recursive = TRUE)

f <- function() {
  s <- local_stash()
  stash_set(s, "n", 1:3)
  stash_get(s, "n")
}
f()
#> [1] 1 2 3
```
