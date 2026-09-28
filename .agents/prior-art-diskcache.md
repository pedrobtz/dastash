# diskcache and polars-diskcache — what they are for

Reference notes on the two Python libraries `dastash` is modelled on. This is about what
they do and why people reach for them; `design.md` §1.3 and §3.12 are where the mapping
onto R and mdbx lives.

> **Sources.** The `diskcache` sections are stated from the library's documented
> behaviour and defaults. The `polars-diskcache` sections are taken from its repository
> README at <https://github.com/lmmx/polars-diskcache>, read 2026-09-03; the code
> examples in §7 are the README's own, lightly trimmed.

---

# 1. diskcache in one paragraph

[`diskcache`](https://github.com/grantjenks/python-diskcache) (Grant Jenks, Apache-2.0)
is a disk-backed cache and key-value store for Python. Pure Python, no dependencies, no
server. One SQLite database holds the metadata and the small values; values above a size
threshold are written as separate files and the row keeps a pointer. It is safe across
threads and processes, it expires and evicts on a policy you choose, it bounds its own
size, and it has been stable for a decade.

The pitch that sells it is the benchmark: for a cache local to one machine it is
competitive with — often faster than — memcached or Redis, because there is no network
hop and no server to run. You get most of what a cache server gives you by importing a
module.

---

# 2. What people actually use it for

Six distinct jobs, and they are worth separating because they pull the design in
different directions.

## 2.1 Persistent memoization

The most common use by a wide margin. A function is expensive — an HTTP call, a query, a
model inference, a parse — and its results should survive the process.

```python
from diskcache import Cache

cache = Cache("/tmp/mycache")

@cache.memoize(expire=3600, tag="prices")
def fetch_prices(exchange, date):
    return http_get(...)
```

Unlike `functools.lru_cache` this survives a restart, and unlike a module-level dict it
is shared by every process on the machine. That last property is what makes it the
default choice for scripts, notebooks, cron jobs and web workers that all want the same
answer.

## 2.2 Caching objects too large to keep in memory

The `disk_min_file_size` threshold (32 KiB by default) means large values never sit in
the SQLite row: they become files. So a cache of trained models, image tensors, parsed
documents or data frames costs almost nothing in the database, and reading one back is a
file read rather than a BLOB fetch.

`cache.set(key, value, read=True)` stores from a file-like object without materialising
it, and `cache.read(key)` hands back a file handle rather than a value. That pair is what
makes multi-gigabyte entries practical.

## 2.3 A cache server you do not have to run

Teams reach for Redis or memcached and inherit a service to deploy, monitor, secure and
pay for. When every consumer is on one machine, `diskcache` deletes that whole category
of work. This is the argument its documentation leads with, and it is the reason it turns
up in Django settings, Airflow tasks and CI pipelines.

## 2.4 A Django cache backend

`diskcache.DjangoCache` plugs into `CACHES` and exposes the extra features (tags,
`read=`, eviction policy) that Django's own file-based backend lacks. For a single-server
Django deployment it removes the memcached dependency outright.

## 2.5 Cross-process coordination

Because the cache is a transactional store shared by every process, it can carry
synchronisation primitives. `diskcache.recipes` ships them:

- `Lock`, `RLock` — mutual exclusion across processes, with an expiry so a dead holder
  does not wedge the system
- `BoundedSemaphore` — bounded concurrency, e.g. "at most three workers may hit this API"
- `throttle` — a rate-limiting decorator
- `barrier` — serialise calls to a function through a lock

People use these when they need coordination but not a coordination service.

## 2.6 Persistent data structures and job queues

`Deque` and `Index` are `collections.deque` and a `MutableMapping` backed by a cache
directory. `Deque` gives O(1) appends and pops at both ends and is used as a durable job
queue between processes; `Index` is a persistent dict.

Underneath both are `Cache.push()`, `Cache.pull()` and `Cache.peek()`, which mint
monotonically increasing keys so that "the front" and "the back" are well defined. Those
three methods are usable directly for a producer/consumer queue.

---

# 3. How it works

One table and a handful of indexes:

```sql
CREATE TABLE Cache (
  rowid        INTEGER PRIMARY KEY,
  key          BLOB,
  raw          INTEGER,
  store_time   REAL,
  expire_time  REAL,
  access_time  REAL,
  access_count INTEGER DEFAULT 0,
  tag          BLOB,
  size         INTEGER DEFAULT 0,
  mode         INTEGER DEFAULT 0,
  filename     TEXT,
  value        BLOB
);

CREATE UNIQUE INDEX Cache_key_raw     ON Cache(key, raw);
CREATE        INDEX Cache_expire_time ON Cache(expire_time);
```

Two indexes always exist. The rest are **created on demand**, which is a detail worth
noticing: the eviction index depends on the policy (`store_time`, `access_time` or
`access_count`), and the tag index is off by default and created only by
`create_tag_index()`. An index nobody reads is a cost on every write, and diskcache
declines to pay it.

Every index exists to answer one question in order and stop early — `ORDER BY expire_time
LIMIT n` for expiry, `ORDER BY access_time LIMIT n` for LRU eviction, and so on. None of
the queries is relational: no joins, no query planner, no SQL that a sorted key-value
store could not serve. That observation is the whole basis of `design.md`.

**Values above the threshold become files** under the cache directory, at a path derived
from 16 random bytes: `<dir>/<xx>/<yy>/<rest>.val`, two levels of 256 subdirectories. The
name is random, **not** a content hash, so identical values are stored twice and
`check()` is what finds files nothing points at.

---

# 4. The features, one at a time

## 4.1 The mapping API

```python
cache.set(key, value, expire=None, read=False, tag=None, retry=False)
cache.add(key, value, ...)            # only if absent; True if it landed
cache.get(key, default=None, read=False, expire_time=False, tag=False, retry=False)
cache.pop(key, default=None, ...)     # get and delete
cache.touch(key, expire=None, ...)    # extend a deadline
cache.delete(key, retry=False)
cache.incr(key, delta=1, default=0, retry=False)
cache.decr(key, delta=1, default=0, retry=False)
cache.read(key)                       # a file handle

cache[key] = value                    # __setitem__, retries
value = cache[key]                    # __getitem__, KeyError on a miss
key in cache                          # __contains__
del cache[key]
len(cache)                            # entry count
for key in cache: ...                 # insertion order
for key in cache.iterkeys(): ...      # sorted key order
```

Two verbs for a miss — `get()` returns a default, `cache[key]` raises `KeyError` — which
is a distinction `dastash` copies.

`get(..., expire_time=True, tag=True)` returns the metadata alongside the value, which is
how you ask "when does this go stale" without a second call.

## 4.2 Expiry

`expire=` is seconds from now; `None` means never. Expiry is **lazy**: an entry past its
deadline is invisible to `get()` and `__contains__` before anything has deleted it, so a
read never has to write. `cache.expire()` does the deleting, in bounded batches, and is
also called opportunistically on `set()`.

## 4.3 Tags

Any entry may carry a `tag`, and `cache.evict(tag)` deletes every entry carrying it. This
is the coarse invalidation primitive: tag everything derived from one upstream source,
and drop the lot when that source changes.

The tag index is **not created by default** — `evict()` without it is a full scan. You
opt in with `create_tag_index()` and pay for it on every write.

## 4.4 Eviction and size limits

`size_limit` defaults to 1 GiB. When a `set()` pushes the cache over it, `cull()` runs and
removes up to `cull_limit` (10) entries — expired ones first, then whatever the policy
nominates. Culling in small bounded chunks on the writing thread is what keeps the limit
honest without a background process, and there is no background process.

| `eviction_policy` | Index used | Behaviour |
|---|---|---|
| `least-recently-stored` | `store_time` | **Default.** Oldest write goes first |
| `least-recently-used` | `access_time` | Classic LRU |
| `least-frequently-used` | `access_count` | Fewest reads goes first |
| `none` | — | Never evicts; `size_limit` is not enforced |

The default is `least-recently-stored` for a specific reason: it is the only policy that
requires **no write on a read**. LRU and LFU must update `access_time` or `access_count`
on every `get()`, which turns reads into writes and serialises them.

## 4.5 Large values and `read=`

```python
with open("model.bin", "rb") as f:
    cache.set("model", f, read=True)   # streamed to a file, never materialised

handle = cache.read("model")           # a file object, not bytes
```

Values under `disk_min_file_size` (32 KiB) live in the row as a BLOB; above it they
become files. `read=True` on `set()` says "this is already a stream, store it as one";
`cache.read()` gives one back. For inline values `read()` returns an `io.BytesIO`, so the
caller does not have to care which happened.

## 4.6 Serialization is pluggable

The `Disk` class decides how keys and values become bytes.

- **`Disk`** (default) — pickle. Any picklable object is a legal key or value.
- **Raw keys** — `bytes`, `str`, `int` and `float` keys are stored as native SQLite
  values rather than pickles, which is what makes `iterkeys()` sort them meaningfully and
  keeps them legible in the database.
- **`JSONDisk`** — zlib-compressed JSON, for a cache other languages can read.
- **A subclass** — override `put`/`get`/`store`/`fetch` for a custom format. This is the
  hook `polars-diskcache` and anything Parquet-shaped hangs off.

## 4.7 Transactions, timeouts and concurrency

SQLite in WAL mode with `synchronous=NORMAL`. Readers do not block; writers serialise.

```python
with cache.transact():
    cache.incr("total", 7)
    cache.set("last", value)
```

Everything in the block commits or rolls back together.

`Cache(directory, timeout=60)` bounds how long an operation waits for the write lock.
Past it, `diskcache.Timeout` is raised — and most methods take `retry=False` by default,
meaning *"raise rather than block indefinitely"*. `retry=True` retries until it succeeds.
The subscript operators (`cache[key]`) retry; the method forms do not. That asymmetry is
deliberate: the dict-like syntax should behave like a dict, and the method form should let
you handle contention.

## 4.8 Statistics and integrity

- `cache.stats(enable=True, reset=False)` → `(hits, misses)`. **Off by default**, because
  counting a hit means writing.
- `cache.volume()` → estimated bytes on disk: the database plus the sum of the file sizes.
- `cache.check(fix=False)` → a list of warnings: rows whose file is missing, files nothing
  references, sizes that disagree with reality, metadata counts that have drifted.
  `fix=True` repairs what it can.

The `statistics` switch and the eviction policy are the same trade seen twice: **anything
that has to be updated on a read makes reads into writes**, so diskcache makes each one
opt-in and tells you what it costs.

## 4.9 `memoize` and `memoize_stampede`

```python
@cache.memoize(name=None, typed=False, expire=None, tag=None, ignore=())
def fetch(exchange, date): ...

fetch.__cache_key__("XSWX", date)     # the key, so you can delete it
```

The key is built from the function's qualified name plus its arguments — **not** from its
code, so editing the body does not invalidate the cache. `typed=True` makes `1` and `1.0`
distinct keys; `ignore=` drops arguments that should not affect identity.

`memoize_stampede(cache, expire, beta=1)` is the interesting one. A plain expiring cache
has a failure mode: the moment a popular entry expires, every process misses at once and
they all recompute it. `memoize_stampede` implements probabilistic early recomputation
(the "XFetch" algorithm) — as an entry approaches its deadline, each reader has a small,
growing chance of refreshing it early in a background thread while everyone else keeps
getting the still-valid cached value. The entry is therefore almost never actually cold.

## 4.10 `FanoutCache`

```python
from diskcache import FanoutCache
cache = FanoutCache("/tmp/mycache", shards=8, timeout=0.010)
```

SQLite allows one writer at a time, so a write-heavy workload queues. `FanoutCache` shards
across N independent databases (`000/`, `001/`, …), picking one by hashing the key. Eight
writers can then proceed in parallel because they are hitting eight databases.

Two consequences to know:

- `size_limit` is divided among the shards, so a badly skewed key distribution evicts
  unevenly.
- **`FanoutCache` never raises `Timeout`.** It swallows it and returns the default — a
  miss instead of an error. That is the right call for a cache and the wrong one for a
  store, and it is worth knowing which you are using.

## 4.11 The recipes

`diskcache.recipes` is a small library of things built on top of the cache rather than
inside it: `Averager`, `Lock`, `RLock`, `BoundedSemaphore`, `throttle`, `barrier`,
`memoize_stampede`. They are a demonstration that a transactional shared store is enough
to build coordination on, and they are separate from the core for a reason — none of them
is a caching feature.

---

# 5. Settings and defaults

Stored in the database and readable or settable with `cache.reset(key, value)`, so every
process attached to the directory agrees.

| Setting | Default | Meaning |
|---|---|---|
| `eviction_policy` | `least-recently-stored` | §4.4 |
| `size_limit` | `2**30` (1 GiB) | Byte ceiling before culling |
| `cull_limit` | `10` | Entries removed per `set()` when over the limit |
| `disk_min_file_size` | `2**15` (32 KiB) | Above this, values become files |
| `statistics` | `0` (off) | Hit/miss counting |
| `tag_index` | `0` (off) | Index for `evict(tag)` |
| `disk_pickle_protocol` | highest | Pickle protocol |
| `sqlite_journal_mode` | `wal` | Readers do not block writers |
| `sqlite_synchronous` | `1` (NORMAL) | Durability/throughput trade |
| `sqlite_auto_vacuum` | `1` (FULL) | Reclaim pages on delete |
| `sqlite_cache_size` | `2**13` pages | 8192 pages of page cache |
| `sqlite_mmap_size` | `2**26` (64 MiB) | Memory-mapped I/O window |
| `timeout` | `60` s | Constructor argument, not a stored setting |

The three defaults that shape behaviour most are `least-recently-stored`, `statistics=0`
and `tag_index=0` — all three chosen so that **an ordinary read touches nothing**.

---

# 6. What diskcache deliberately does not do

Worth stating, because the absences are as informative as the features:

- **No identity model.** Keys are opaque pickles. The cache will store the wrong value
  under a key forever and has no way to know.
- **No content addressing.** File names are random, so identical values are stored twice.
- **No query.** You can iterate keys and evict by tag; you cannot ask "everything where
  `exchange == 'XSWX'`".
- **No remote backend.** One directory on one machine, by design.
- **No revalidation.** No ETag, no conditional refresh, no `stale-while-revalidate` beyond
  `memoize_stampede`.
- **Single machine.** The locking is POSIX advisory locking through SQLite, which is not
  reliable over NFS or SMB.

---

# 7. polars-diskcache

A decorator that caches functions returning Polars `DataFrame`s and `LazyFrame`s, storing
each result as a Parquet file with `diskcache` tracking where it went. Louis Maddox, MIT,
Python 3.13+, depends on `polars` and `diskcache`.

**The import name is `plcache`, not the distribution name:**

```python
from plcache import cache, PolarsCache
```

## 7.1 The problem

Caching a data frame with a general-purpose cache means pickling it. That is wrong in
three ways at once:

- **Slow and large.** Pickle is row-agnostic and uncompressed; a frame that is 40 MB as
  Parquet is several times that as a pickle, and both directions cost CPU.
- **Opaque.** A pickle is readable only by Python, only with compatible library versions.
  A cached frame stops being data and becomes a Python artifact.
- **All or nothing.** You deserialise the entire frame to read one column. There is no
  predicate pushdown, no column pruning, no lazy scan — precisely the things Polars is
  good at.

## 7.2 Basic use

```python
import polars as pl
from plcache import cache

@cache()
def expensive_computation(n: int) -> pl.DataFrame:
    return pl.DataFrame({"values": range(n), "squared": [i**2 for i in range(n)]})

df1 = expensive_computation(1000)   # computes, writes Parquet
df2 = expensive_computation(1000)   # reads the Parquet back
assert df1.equals(df2)
```

That is the whole surface for most uses: one decorator, no arguments.

**The frame type is preserved.** A function that returns a `LazyFrame` gets a `LazyFrame`
back from the cache, not a materialised `DataFrame`:

```python
@cache()
def get_lazy_data(n: int) -> pl.LazyFrame:
    return pl.LazyFrame({"x": range(n)})

@cache()
def get_eager_data(n: int) -> pl.DataFrame:
    return pl.DataFrame({"x": range(n)})

get_lazy_data(100)    # LazyFrame
get_eager_data(100)   # DataFrame
```

This is the point of the library rather than a convenience. A cached `LazyFrame` is a
scan over the cached Parquet file, so a filter or a projection applied afterwards pushes
down into the file instead of materialising it — the cached value stays *queryable in
place*, which a pickle can never be.

## 7.3 What it puts on disk

Three things, and the third is the unusual one:

```text
.polars_cache/
├── metadata/                       diskcache's SQLite database: key -> blob path
├── blobs/
│   ├── a1b2c3d4….parquet           the actual data
│   └── e5f6g7h8….parquet
└── functions/                      human-readable symlinks into blobs/
    └── __main__/
        └── expensive_computation/
            ├── arg0=1000/
            │   └── output.parquet -> ../../../blobs/a1b2c3d4….parquet
            └── arg0=5000/
                └── output.parquet -> ../../../blobs/e5f6g7h8….parquet
```

- **`metadata/`** is a `diskcache` store used as a key → path map. The transaction, the
  size accounting and the eviction of §4 are all delegated to it.
- **`blobs/`** holds the Parquet files, named by a SHA-256 digest.
- **`functions/`** is a browsable symlink tree — module, then function, then arguments.
  It exists so a human, or `ls`, or a DuckDB glob, can navigate a cache whose real
  filenames are hashes. `nested=False` flattens it to `__main__.expensive_computation/`.

**The symlink tree is the idea worth stealing.** A content-addressed store is unbrowsable
by construction, and this restores browsability without giving up the flat hash namespace.

## 7.4 The cache key

```python
call_str  = f"{func_name}({bound_args})"
cache_key = hashlib.sha256(call_str.encode()).hexdigest()
```

Arguments are bound through `inspect` first, so positional and keyword forms of the same
call agree and keyword arguments are sorted. The blob is then named by that digest —
**the file is addressed by the call, not by its content**, so two calls that happen to
produce identical frames are stored twice. That is the opposite of diskcache's random
filenames *and* the opposite of content addressing; it is a third choice, and what it buys
is that the blob name is derivable from the call without consulting the metadata.

Note what the key is made of: the `repr` of the bound arguments. That is legible, which is
what makes the symlink tree possible at all, and it is fragile in the way any `repr`-based
identity is — an argument whose `repr` embeds a memory address, or whose formatting shifts
between library versions, silently changes the key. `cache_key=` is the escape hatch, and
§7.6 is how you use it.

## 7.5 Configuration

`@cache(...)` and `PolarsCache(...)` take the same options:

| Option | Default | Meaning |
|---|---|---|
| `cache_dir` | `.polars_cache` in cwd | Where everything lives |
| `use_tmp` | `False` | Put it in the system temp directory instead |
| `hidden` | `True` | Dot-prefix the directory name |
| `size_limit` | `2**30` (1 GiB) | Passed through to diskcache |
| `symlinks_dir` | `"functions"` | Name of the browsable tree |
| `nested` | `True` | `module/function/` vs flat `module.function/` |
| `trim_arg` | `50` | Max argument length in a directory name |
| `symlink_name` | `"output.parquet"` | Filename at the leaf of the tree |
| `cache_key` | — | `(func, bound_args) -> str`, overrides §7.4 |
| `entry_dir` | — | `(func, bound_args) -> str`, names the symlink directory |

```python
@cache(cache_dir="/path/to/my/cache")
def my_function(): ...

@cache(use_tmp=True)            # system temp
def scratch_function(): ...

@cache(hidden=False)            # "polars_cache", not ".polars_cache"
def visible_function(): ...

@cache(nested=False)            # __main__.flat_example/ instead of __main__/flat_example/
def flat_example(): ...

@cache(symlinks_dir="analytics", symlink_name="results.parquet")
def analytics_function(): ...
```

There is **no `expire=` and no TTL.** Freshness is not part of the model: entries live
until the size limit evicts them or you clear the cache. That is a real gap relative to
`diskcache` itself, and it is worth knowing before reaching for this on anything that goes
stale on a clock.

## 7.6 Custom keys — excluding arguments from identity

The most useful thing `cache_key=` does is keep debugging flags out of the key, so that
`debug=True` and `debug=False` share a cache entry:

```python
from plcache import PolarsCache

def preprocessing_cache_key(func, bound_args):
    cache_params = {k: v for k, v in bound_args.items()
                    if k not in ["debug", "verbose", "log_level"]}
    return f"{func.__name__}({cache_params})"

cache = PolarsCache(cache_dir="./preprocessing_cache",
                    cache_key=preprocessing_cache_key)

@cache.cache_polars()
def preprocess_data(raw_data, normalize=True, remove_outliers=False, debug=False):
    return expensive_preprocessing(raw_data, normalize, remove_outliers)

# These two share one cache entry:
clean1 = preprocess_data(df, normalize=True, debug=False)
clean2 = preprocess_data(df, normalize=True, debug=True)
```

This is `diskcache.memoize`'s `ignore=` argument, generalised into a callback. Note the
class form: `PolarsCache(...)` plus `@instance.cache_polars()` is how you configure once
and decorate many functions, rather than repeating options on every `@cache()`.

`entry_dir=` does the same job for the symlink tree, naming directories after something
meaningful instead of the raw arguments:

```python
def experiment_dir_name(func, bound_args):
    model = bound_args["model_type"]
    dataset_size = len(bound_args["data"])
    return f"{model}_experiment_{dataset_size}samples"

cache = PolarsCache(cache_dir="./experiments",
                    entry_dir=experiment_dir_name,
                    symlink_name="model_output.parquet")

@cache.cache_polars()
def run_experiment(data, model_type, learning_rate=0.01):
    return train_and_evaluate(data, model_type, learning_rate)

result = run_experiment(large_dataset, "xgboost", 0.001)
# -> ./experiments/functions/…/xgboost_experiment_50000samples/model_output.parquet
```

## 7.7 A worked example — chained caches

The README's stock-analysis example is the shape most real use takes: a cached loader
returning a `LazyFrame`, and a cached analysis over it returning a `DataFrame`, each with
its own cache directory and its own browsable tree.

```python
import polars as pl
from plcache import cache

@cache(cache_dir="./data_cache", symlinks_dir="datasets",
       symlink_name="raw_data.parquet")
def load_stock_data(symbol: str, start_date: str, end_date: str) -> pl.LazyFrame:
    return pl.scan_csv(f"data/{symbol}.csv").filter(
        pl.col("date").is_between(start_date, end_date)
    )

@cache(cache_dir="./analysis_cache", symlinks_dir="technical_analysis",
       symlink_name="indicators.parquet")
def technical_analysis(symbol: str, window: int = 20) -> pl.DataFrame:
    stock_data = load_stock_data(symbol, "2024-01-01", "2024-12-31")
    return stock_data.with_columns([
        pl.col("close").rolling_mean(window).alias("sma"),
        pl.col("close").rolling_std(window).alias("volatility"),
    ]).collect()

aapl = technical_analysis("AAPL", window=20)
```

The inner call stays lazy — `load_stock_data` returns a cached `LazyFrame`, the rolling
windows are composed onto it, and `.collect()` is the only point anything materialises.

Clearing is per-instance:

```python
cache_instance = PolarsCache(cache_dir="./my_cache")
cache_instance.clear()
```

## 7.8 What it buys, and what it costs

**Buys:**

- **Smaller and faster** than pickle for anything columnar, in both directions.
- **Lazily scannable**, per §7.2 — the headline feature.
- **Interoperable.** The cache directory holds real Parquet files that DuckDB, Arrow,
  pandas, Spark and R can all read, and which outlive the Python environment that wrote
  them.
- **Browsable**, via the symlink tree.
- **Schema preserved** by the format rather than by pickle's object graph.

**Costs:**

- **Frames only.** Parquet stores a table, not an arbitrary Python value.
- **A round-trip is not always identity.** Some type and metadata detail is negotiated by
  the format.
- **No expiry** (§7.5).
- **`repr`-based keys** (§7.4).
- **Python 3.13+**, which is a narrow floor for a library this small.

---

# 8. What this means for dastash

The short version; `design.md` is the long one, and its §3.12 maps the two APIs call by
call.

| From diskcache and plcache | dastash's position |
|---|---|
| One table, six indexes, no joins | Named mdbx databases, one per index (`design.md` §1.3, §7.2) |
| Values above a threshold become files | Same, at 32 KiB — but content-addressed with refcounts, so identical bytes are stored once and deletion is safe (§6.1, §8) |
| Random file names; plcache's blob = hash of the *call* | SHA-256 of the encoded bytes |
| Indexes created on demand | Copied (§7.2) |
| `statistics` off, LRS default, tag index off | Copied, for the same reason: an ordinary read touches nothing (§9.3, D4) |
| Lazy expiry, bounded `cull()` on write | Copied (§9.1) |
| `Timeout` with `retry=` | `TRY` plus backoff, then `dastash_busy` (§10) |
| `FanoutCache` for write contention | v1.x; mdbx serialises writers per environment exactly as SQLite does |
| `memoize` keys on arguments, not code | Copied, with an explicit `version =` lever (§3.8) |
| Pickle as the default format | RDS, with the ban on hashing `serialize()` output for *identity* (§5.2) |
| plcache's Parquet path | `codec_parquet()`, `stash_path()` and `stash_lazy()` (§6.3–§6.5) |
| A `LazyFrame` comes back lazy | A lazy arrow or polars frame comes back as a scan of the cached file (§6.4) |
| plcache keys on `repr(bound_args)` | A specified canonical encoding (§5) — same goal, but `1L` and `1` agree and no `repr` can drift |
| `cache_key=`, `ignore=` | `key =` and `omit =` on `stash_memoise()` (§3.8) |
| plcache's `functions/` symlink tree | `stash_tree()`: derived, on demand, relative symlinks (§6.6) |
| plcache has no expiry | `expire =` (§3.4) |

The one thing neither library has is a notion of what a value *is*. diskcache will store
anything under any key and cannot tell you it is wrong. That gap is the deferred typed
layer (`typed-layer.md`), not the cache.
