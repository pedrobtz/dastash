# Operating a shared cache

A cache is meant to be shared: by interactive sessions, scheduled jobs
and parallel workers on one machine, all at once. This article covers
what that asks of you, and what dazcache guarantees in return.

``` r

library(dazcache)
dir <- file.path(tempdir(), "shared")
s <- cache(dir, size_limit = 1024^2)
```

## Where a cache can live

On a **local filesystem** of the machine whose processes use it. The
engine underneath, ‘libmdbx’, memory-maps the database and coordinates
writers through a lock file, and both need a local filesystem. A cache
on a network filesystem (NFS, SMB, a cloud file share) is not supported.

## Many processes

Any number of processes can read at once, and never wait: a read sees
the last committed state. Writes take turns. A write that waits longer
than `timeout` seconds (60 by default) for another process’s write
raises `dazcache_busy`, not a hang.

![Readers never wait; one writer holds the lock and the next waits its
turn.](processes.svg)

Readers never wait; one writer holds the lock and the next waits its
turn.

Each process opens the cache itself. A handle cannot be carried into a
forked child, such as a
[`parallel::mclapply()`](https://rdrr.io/r/parallel/mclapply.html)
worker. Using it there raises `dazcache_forked`, so open the cache
inside the worker:

``` r

parallel::mclapply(keys, function(k) {
  s <- cache(dir)
  on.exit(cache_close(s))
  cache_get(s, k, default = NULL)
})
```

Workers started as fresh processes (‘callr’, ‘mirai’, ‘future’ with
multisession) have nothing to inherit, and open the cache like any other
process.

Every single operation is atomic across processes. Eight processes
calling
[`cache_incr()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md)
on one key count eight.
[`cache_add()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md)
writes only if there is no entry.
[`cache_pop()`](https://pedrobtz.github.io/dazcache/reference/cache_add.md)
reads and deletes in one step.

``` r

cache_incr(s, "jobs-run")
#> [1] 1
cache_add(s, "lock/nightly", Sys.getpid(), expire = 3600)
#> [1] TRUE
cache_add(s, "lock/nightly", Sys.getpid())
#> [1] FALSE
```

## Transactions

[`cache_transact()`](https://pedrobtz.github.io/dazcache/reference/cache_transact.md)
makes a block of writes atomic: all commit, or none do.

``` r

cache_set(s, "balance", 100)
cache_transact(s, {
  cache_set(s, "balance", cache_get(s, "balance") - 30)
  cache_incr(s, "withdrawals")
})
#> [1] 1
cache_get(s, "balance")
#> [1] 70
```

It holds the write lock while it runs, so other processes’ writes wait
for it. Keep it short, and never compute something slow inside it. It is
also the fastest way to write many entries: making a write durable is
the expensive part, and a transaction pays it once.

Memoised functions follow the same rule. Two processes that miss the
same call at the same moment both compute it, and one result is kept.
That is duplicated work, never a wrong answer.

## Durability

By default (`durability = "safe"`) every write is on disk before it
returns. `durability = "fast"` skips waiting for the disk: a crash of
the machine can lose recent writes, but never damages the cache.
`"unsafe"` can damage it, for cachees you can rebuild. The first process
to open a cache sets this for every process that opens it while it is
open;
[`cache_stats()`](https://pedrobtz.github.io/dazcache/reference/cache_entries.md)
reports what is in force.

``` r

cache_stats(s)$durability
#> [1] "safe"
```

## Staying within a size limit

`size_limit` bounds what the entries hold. A write that goes over it
evicts the least recently stored entries, a few at a time, so the limit
holds without a background process.
[`cache_cull()`](https://pedrobtz.github.io/dazcache/reference/cache_cull.md)
finishes the job at once. Expired entries go first.

``` r

for (i in 1:5) cache_set(s, paste0("frame/", i), runif(5e4))
cache_count(s)
#> [1] 2
cache_cull(s)
cache_count(s)
#> [1] 2
```

The database file keeps the pages it frees for reuse rather than
shrinking, so
[`cache_volume()`](https://pedrobtz.github.io/dazcache/reference/cache_keys.md),
which reports bytes on disk, can stay above the limit.

## Checking and repairing

A process that dies in the middle of a write can leave, at most, a file
that nothing refers to. On Linux and Windows the write lock it held is
released at once. On macOS it is not, a limitation of the storage engine
there: reads carry on, but every write raises `dazcache_busy` until
every process with the cache open has closed it; the next process to
open it then recovers the lock.
[`cache_check()`](https://pedrobtz.github.io/dazcache/reference/cache_check.md)
finds that, and any other damage. `repair = TRUE` fixes it, and
`hash = TRUE` also verifies every stored file’s content.

``` r

cache_check(s)
#> [1] kind     key      path     detail   repaired
#> <0 rows> (or 0-length row.names)
cache_check(s, repair = TRUE)
#> [1] kind     key      path     detail   repaired
#> <0 rows> (or 0-length row.names)
```

Run it now and then from a maintenance job, as you would
[`cache_cull()`](https://pedrobtz.github.io/dazcache/reference/cache_cull.md).

``` r

cache_close(s)
unlink(dir, recursive = TRUE)
```
