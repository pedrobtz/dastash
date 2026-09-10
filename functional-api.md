# A functional API for dastash

**Status:** speculative design, one day
**Relation to `design.md`:** that document specifies an R6 object — `s$get()`, `s$set()`.
This is the same semantics behind a functional surface, and it is the surface most R users
would rather have.

Nothing here changes `design.md`'s contract. Every function below is a name for a
transition already defined in `cache-model.md`; §14 lists the four places where the
translation is not mechanical and a decision has to be made.

---

# 0. Why bother

R's object systems are unpleasant to *use* even when they are pleasant to implement.
`s$get("k")` gives up almost everything the language is good at: it does not pipe, it does
not compose, `s$get` is not a function you can pass to `map()`, autocomplete is the only
discovery mechanism, and every method is invisible to `methods()`, to S3 dispatch, and to
anyone reading the NAMESPACE.

A functional surface gets those back:

```r
s |> stash_set("a", 1) |> stash_set("b", 2)

keys |> purrr::map(\(k) stash_get(s, k, default = NULL))

fetch <- stashed(fetch, stash = s, expire = 3600)
```

The R6 object does not go away — it is a fine implementation of a mutable handle. It stops
being the *interface*.

---

# 1. The conventions, stated once

Ten rules. Every function below follows them, and stating them here means the reference in
§13 needs almost no prose.

1. **`stash_` prefix, snake_case, verb last.** `stash_get`, `stash_set_many`,
   `stash_entries`. One family, greppable, no collisions with base R.
2. **The stash is the first argument, always, and never optional.** This is what makes
   `|>` work, and §14.1 explains why there is no ambient default.
3. **One function, one return type.** A function's return type never depends on the value
   of an argument. This is the rule `diskcache`'s
   `get(key, read=, expire_time=, tag=)` breaks, and the reason `stash_get`, `stash_path`,
   `stash_lazy` and `stash_info` are four functions rather than one with flags.
4. **Questions return answers; effects return the stash, invisibly.** `stash_has()`
   returns a logical because it asks something. `stash_set()` returns the stash invisibly
   because it does something. `stash_add()` returns a logical because it does something
   *and* the outcome is the point.
5. **Scalar functions are scalar; plural functions say so.** `stash_get()` takes one key
   and returns one value. `stash_get_many()` takes a character vector and returns a named
   list. Nothing silently changes shape. The exception is genuinely vectorised predicates —
   `stash_has()` is vectorised over `key`, because a logical vector is the only sensible
   return.
6. **Tabular things are data frames.** `stash_entries()` and `stash_stats()` return plain
   `data.frame`s with no row names and no factors — tibble-shaped, so `tibble::as_tibble()`
   and every dplyr verb work, without `tibble` becoming a hard dependency (§14.4).
7. **Configuration is values.** `codec_parquet()`, `evict_lru()`, `expire_in()` are pure
   functions returning classed lists. They can be stored in variables, compared, printed,
   and passed around. No configuration is expressed as a magic string where a constructor
   would do.
8. **Pure things are pure.** Key construction, canonicalisation, codecs and policies touch
   nothing. `stash_key()` is a pure function of its arguments and is testable without a
   store on disk — §4.
9. **Errors are classed conditions**, per `design.md` §12, and every function that can miss
   offers a `default` rather than making you write a `tryCatch`.
10. **`...` is checked.** Functions that take `...` for a real reason validate it;
    functions that do not, do not have it. A misspelled argument is an error, not a
    silently ignored one.

---

# 2. The API in use

Before the reference, the tour. This is the whole design in thirty lines.

```r
library(dastash)

s <- stash("~/.cache/prices")

# --- write ------------------------------------------------------------------
s |> stash_set("XSWX/2026-08-29", quotes, expire = 3600, tag = "XSWX")

s |> stash_set_many(list(a = 1, b = 2), tag = "small")

# --- read -------------------------------------------------------------------
stash_get(s, "XSWX/2026-08-29")            # the value, or dastash_not_found
stash_get(s, "nope", default = NULL)       # the value, or NULL
stash_has(s, c("a", "b", "nope"))          # TRUE TRUE FALSE

# --- keys are values ---------------------------------------------------------
k <- stash_key(exchange = "XSWX", date = as.Date("2026-08-29"))
k                                          # <dastash_key> date=d:2026-08-29
                                           #               exchange=s:XSWX
stash_get(s, k)

# --- a cache is an adverb over a function ------------------------------------
fetch_prices <- stashed(fetch_prices, stash = s, expire = 3600, tag = "prices")

fetch_prices("XSWX", as.Date("2026-08-29"))          # computes, stores
fetch_prices("XSWX", as.Date("2026-08-29"))          # hits
stashed_forget(fetch_prices, "XSWX", as.Date("2026-08-29"))

# --- large frames stay on disk -----------------------------------------------
s |> stash_set("trades", df, codec = codec_parquet())

stash_lazy(s, "trades") |>                 # an arrow Dataset, not a data frame
  dplyr::filter(px > 100) |>
  dplyr::summarise(n = dplyr::n()) |>
  dplyr::collect()

stash_path(s, "trades")                    # ".../blobs/9f/9fbc….parquet"

# --- the catalogue is a data frame -------------------------------------------
stash_entries(s, tag == "XSWX") |>
  dplyr::arrange(dplyr::desc(bytes)) |>
  dplyr::select(key, bytes, expires)

# --- maintenance -------------------------------------------------------------
s |> stash_expire() |> stash_cull()
stash_evict(s, tag = "XSWX")

stash_volume(s)                            # <bytes> 412 MB
stash_stats(s)                             # one-row data frame
```

---

# 3. Opening, closing, scoping

```r
stash(dir, ...)                            # open or create; returns a <dastash_stash>
stash_close(stash)                         # returns the stash, invisibly
stash_is_open(stash)                       # logical
local_stash(dir = tempfile(), ..., .frame = parent.frame())
```

`stash()` takes the settings of `design.md` §8.1, but as values rather than strings:

```r
s <- stash(
  "~/.cache/prices",
  eviction   = evict_lru(),
  size_limit = "2GB",                      # or a number of bytes
  codec      = codec_auto(),
  durability = "safe"
)
```

`local_stash()` is the `withr` idiom: it creates a stash, registers cleanup on the calling
frame, and **returns it**. Because it returns the stash rather than installing it
somewhere ambient, there is no hidden state:

```r
test_that("expired entries are invisible", {
  s <- local_stash()
  stash_set(s, "k", 1, expire = -1)
  expect_false(stash_has(s, "k"))
})
```

`with_stash(dir, code, ...)` is the expression form, for a script that wants a stash for
exactly one block.

---

# 4. The pure core

The functions with no I/O. They are separated out because they are the ones worth unit
testing exhaustively, and because a user should be able to compute a key without touching
a disk.

```r
stash_key(...)                             # named values -> <dastash_key>
stash_key_chr(key)                         # its canonical encoding, a string
stash_key_hash(key)                        # its digest
```

```r
k <- stash_key(exchange = "XSWX", date = as.Date("2026-08-29"))

stash_key_chr(k)
#> "date=d:2026-08-29\nexchange=s:XSWX"

identical(
  stash_key(date = as.Date("2026-08-29"), exchange = "XSWX"),
  stash_key(exchange = "XSWX", date = as.Date("2026-08-29"))
)
#> TRUE                                    # field order is not identity
```

That last property is `design.md` §4's name-sorted encoding, made observable. A user can
see what their key *is*, compare two keys, and store one in a variable. A key is a value.

A plain string is also a key — `stash_get(s, "XSWX/2026-08-29")` — and the prefix
convention it enables is the reason `stash_keys(prefix =)` exists.

**Codecs and policies** are the other pure values:

```r
codec_auto()  codec_rds()  codec_raw()  codec_file()  codec_qs2()  codec_parquet()

evict_stored()  evict_lru()  evict_lfu()  evict_none()

expire_in(3600)          # or a difftime
expire_at(as.POSIXct("2026-12-31"))
expire_never()
```

`expire =` accepts a number of seconds, a `difftime`, or one of these — the constructors
exist so that `expire_at()` is expressible at all, which a bare number cannot do.

---

# 5. Reading

```r
stash_get(stash, key, default)             # the value
stash_get_many(stash, keys, default)       # a named list, one entry per key
stash_has(stash, key)                      # logical, vectorised over key
stash_info(stash, key)                     # one-row data frame, or NULL
stash_path(stash, key)                     # character(1): the blob path
stash_lazy(stash, key)                     # a lazy handle over the blob
```

**`stash_get()` errors when `default` is not supplied**, and returns `default` when it is.
There is no sentinel to learn and no flag to set:

```r
stash_get(s, "nope")
#> Error in `stash_get()`:
#> ! No entry for key "nope".
#> ℹ Supply `default` to return a value instead of erroring.
#> Class: dastash_not_found

stash_get(s, "nope", default = NULL)
#> NULL
```

This is rule 3 doing real work. `diskcache` has `get()` returning a default and
`cache[key]` raising; the functional translation of that pair is one function whose
behaviour is selected by whether an argument is present — which is `missing()`, an ordinary
R idiom, rather than a second name.

**`stash_lazy()` is the interesting one.** For a Parquet-backed entry it returns an
`arrow::Dataset` — something dplyr verbs compose onto and which is only read when
`collect()` runs:

```r
stash_lazy(s, "trades") |>
  dplyr::filter(date >= "2026-01-01", px > 100) |>
  dplyr::collect()
```

The filter and the projection push down into the file; the cached value is queried in
place and never fully materialises. This is `polars-diskcache`'s LazyFrame preservation,
and it is the one capability `cache-model.md` §16 identifies as outside the model — the
observation is not `get(k)` but `q(B(M(k)))` for a query `q`.

For a non-file-backed entry `stash_lazy()` errors rather than silently materialising, per
rule 3: a function that sometimes returns a lazy handle and sometimes a data frame is
worse than one that fails.

---

# 6. Writing

```r
stash_set(stash, key, value, expire = NULL, tag = NULL, codec = NULL)   # -> stash
stash_set_many(stash, values, expire = NULL, tag = NULL, codec = NULL)  # -> stash
stash_add(stash, key, value, ...)          # -> logical: did it land?
stash_touch(stash, key, expire)            # -> stash
stash_delete(stash, key)                   # -> stash
stash_pop(stash, key, default)             # -> the value
stash_incr(stash, key, by = 1L)            # -> the new value, integer64
stash_decr(stash, key, by = 1L)            # -> the new value
```

`stash_set_many()` takes a **named list**, which is how R spells "a set of key-value
pairs", and commits it in one transaction:

```r
s |> stash_set_many(list(a = 1, b = 2, c = 3))
```

The counters return their new value rather than the stash, because a counter you cannot
read is not useful and a second round trip to read it would not be atomic:

```r
n <- stash_incr(s, "requests")
```

`stash_pop()` and `stash_add()` likewise return their answer. Everything else in this
section returns the stash invisibly and chains.

---

# 7. Enumerating and querying

```r
stash_keys(stash, prefix = NULL, n = Inf)          # character vector
stash_entries(stash, ..., n = Inf)                 # data frame
stash_size(stash)                                  # integer: live entries
stash_volume(stash)                                # <bytes>
stash_stats(stash)                                 # one-row data frame
```

`stash_entries()` returns one row per live entry with stable columns:

| Column | Type | |
|---|---|---|
| `key` | chr | |
| `bytes` | dbl | encoded size |
| `codec` | chr | the codec that wrote it |
| `tag` | chr | `NA` when untagged |
| `stored` | POSIXct | |
| `accessed` | POSIXct | as last flushed |
| `expires` | POSIXct | `NA` for never |
| `inline` | lgl | `FALSE` when file-backed |
| `blob` | chr | content hash, `NA` when inline |

`...` takes **data-masking predicates** over those columns:

```r
stash_entries(s, tag == "XSWX")
stash_entries(s, expires < Sys.time() + 3600)
stash_entries(s, bytes > 1e6, inline == FALSE)
```

Three of these push down into an index — `tag`, `expires`, and a `key` prefix — and the
rest filter after the scan. That distinction is documented per column rather than hidden,
because on a large store it is the difference between a cursor seek and reading every
record. Anything more complicated is a `dplyr` call on the result, and the API does not
try to be a query language:

```r
stash_entries(s) |>
  dplyr::filter(stringr::str_detect(key, "^XSWX/")) |>
  dplyr::slice_max(bytes, n = 10)
```

**Why data-masking here and nowhere else.** Tidy eval earns its place when the alternative
is stringly-typed predicates. It does not earn its place for `stash_get(s, key)`, where the
key is a value the user already has. Rule 10.

---

# 8. Maintenance

```r
stash_expire(stash, n = NULL)              # -> stash
stash_evict(stash, tag)                    # -> stash
stash_cull(stash)                          # -> stash
stash_clear(stash)                         # -> stash
stash_check(stash, repair = FALSE, hash = FALSE)   # -> data frame of findings
stash_flush(stash)                         # -> stash
```

All chain except `stash_check()`, which answers a question and so returns a data frame of
findings — one row per problem, with `kind`, `key`, `detail` and `repaired` columns.

`cache-model.md` §4.2 proves these are one operation with different predicates. The API
keeps them as separate names anyway, because the shared abstraction (`forget_P`) is not
something a user should have to instantiate, and because each has a different cost profile.
A `stash_forget(stash, predicate)` general form is listed in §15 as an open question.

---

# 9. Transactions

```r
stash_transact(stash, code)
```

`code` is captured and evaluated with the stash's write transaction held open, so
everything inside commits or rolls back together:

```r
stash_transact(s, {
  stash_delete(s, "old")
  stash_set(s, "new", value)
  stash_incr(s, "generation")
})
```

The stash is named explicitly inside the block rather than made ambient. That is DBI's
`dbWithTransaction()` pattern, it costs three characters per line, and it means the block
is ordinary code that can be extracted into a function without changing meaning.

Per `design.md` §7, blobs are published before the transaction opens and unlinks are
deferred until after it commits — so a `stash_set()` of a large value inside a transaction
is still safe, and the transaction is not held across the encode.

---

# 10. Adverbs

The functional-programming payoff. `stashed()` is to `dastash` what `purrr::safely()` is to
error handling: a function that takes a function and returns a better one.

```r
stashed(f, stash, expire = NULL, tag = NULL, codec = NULL, key = NULL, version = NULL)
```

```r
fetch_prices <- function(exchange, date) {
  httr2::request(...) |> httr2::req_perform() |> parse_prices()
}

fetch_prices <- stashed(fetch_prices, stash = s, expire = 3600, tag = "prices")

fetch_prices("XSWX", as.Date("2026-08-29"))
```

The key is `stash_key()` applied to the matched call arguments, so `f(1, x = 2)` and
`f(x = 2, 1)` are the same call. Two companions make the cache addressable rather than
opaque:

```r
stashed_key(fetch_prices, "XSWX", as.Date("2026-08-29"))     # the key it would use
stashed_forget(fetch_prices, "XSWX", as.Date("2026-08-29"))  # drop that entry
```

That pair is `diskcache`'s `__cache_key__` and it matters more than it looks: without it,
invalidating one call's result means clearing the whole cache.

**`key =` overrides the default keying**, which is how arguments are kept out of identity —
`polars-diskcache`'s `cache_key=` and `diskcache`'s `ignore=`, generalised:

```r
fit <- stashed(fit, stash = s, key = \(args) stash_key(!!!args[c("data_id", "model")]))
```

**`version =` is the explicit invalidation lever.** The key does *not* depend on the
function's body, deliberately — `dastash-design.md` §7.2's argument that identity derived
from implementation invalidates a cache every time a comment moves. When the meaning
genuinely changes, you say so:

```r
fetch_prices <- stashed(fetch_prices, stash = s, version = 2)
```

Two more adverbs worth having:

```r
stash_fallback(f, stash, tag = NULL)   # on error, serve the last good value
stash_only(f, stash)                   # never call f; error on a miss
```

`stash_fallback()` is `stale-if-error` as a function transformer, which is a more honest
place for it than a policy flag: it changes what the function *does*, so it should change
the function.

---

# 11. Base generics

A stash should behave like the thing it resembles where that costs nothing:

```r
length(s)                                  # live entry count
s[["k"]]                                   # stash_get(s, "k")
s[["k"]] <- value                          # stash_set(s, "k", value)
print(s); format(s)
as.list(s)                                 # every value — warns above a threshold
```

`[[` errors on a miss, matching `stash_get()` without a default and matching a list.
`as.list()` exists because someone will want it, and warns because on a 400 GB cache it is
never what they meant.

Not implemented: `names(s)` (use `stash_keys()` — `names()` implies cheap and total,
and it is neither), `[` (a subset of a cache is not a cache), and `c()`.

---

# 12. Conditions

Every class from `design.md` §12, plus the ergonomics:

```r
rlang::try_fetch(
  stash_get(s, k),
  dastash_not_found = \(cnd) NULL,
  dastash_blob_corrupt = \(cnd) { warn_and_repair(); NULL }
)
```

and a predicate family so the common case needs no condition handling at all:

```r
stash_get(s, k, default = NULL)
```

Conditions carry structured fields — `cnd$key`, `cnd$stash`, `cnd$path` — so a handler can
act rather than parse a message.

---

# 13. The complete surface

```r
# open
stash()  stash_close()  stash_is_open()  local_stash()  with_stash()

# pure
stash_key()  stash_key_chr()  stash_key_hash()
codec_auto()  codec_rds()  codec_raw()  codec_file()  codec_qs2()  codec_parquet()
evict_stored()  evict_lru()  evict_lfu()  evict_none()
expire_in()  expire_at()  expire_never()

# read
stash_get()  stash_get_many()  stash_has()  stash_info()  stash_path()  stash_lazy()

# write
stash_set()  stash_set_many()  stash_add()  stash_touch()
stash_delete()  stash_pop()  stash_incr()  stash_decr()

# enumerate
stash_keys()  stash_entries()  stash_size()  stash_volume()  stash_stats()

# maintain
stash_expire()  stash_evict()  stash_cull()  stash_clear()  stash_check()  stash_flush()

# compose
stash_transact()  stashed()  stashed_key()  stashed_forget()
stash_fallback()  stash_only()

# interop
as_cachem()

# generics
length()  [[  [[<-  print()  format()  as.list()
```

Forty-odd exported names, one prefix, no flags that change return types.

---

# 14. Where the translation is not mechanical

Four decisions the object API never had to make.

## 14.1 There is no ambient default stash

The tempting design is an implicit stash so casual use is one call:

```r
stash_set("k", v)          # uses the default
```

It is rejected, because it makes the first argument ambiguous: `stash_set(x, "k")` cannot
be read without knowing whether `x` is a stash or a key, and no amount of dispatch fixes
that for the reader. DBI, arrow and duckdb all require the handle explicitly and the cost
is one short variable name.

`local_stash()` covers the case the ambient default was really for — a throwaway store in
a test or an example — by returning the stash instead of hiding it.

## 14.2 `stash_set()` returns the stash, not the value

The alternative is returning the value, which makes `stash_set()` usable inline:

```r
result <- stash_set(s, "k", compute())     # if it returned the value
```

but breaks chaining, which is the point of the functional API. The inline case is served
by `stashed()`, which is the right tool for it anyway. Chaining wins.

## 14.3 The read journal is visible

`design.md` §9.3 defers access-time updates to an in-process buffer. In an object API that
is invisible. In a functional API it is not, because a user may reasonably ask why
`stash_entries(s)$accessed` disagrees with what they just did.

So `stash_flush()` is exported, `accessed` is documented as "as last flushed", and
`cache-model.md` Result 4b is the justification: eviction accuracy is not a correctness
property, so an approximate `accessed` is a legitimate implementation and not a bug to be
reported.

## 14.4 Data frames, not tibbles

`stash_entries()` returns a plain `data.frame` with no row names and no factors. It is
tibble-shaped, so `as_tibble()` and every dplyr verb work on it, but `tibble` stays out of
`Imports` — `design.md`'s dependency line is short on purpose and a print method is not
worth a dependency. If `tibble` is installed, printing uses it.

---

# 15. Open questions

**Q1 — S7 instead of R6.** `design.md` and `CLAUDE.md` commit to R6 for the stash. A
functional API changes the calculus: with functions as the interface, the object needs no
methods at all, only identity and printing — which is exactly what S7 is good at, and S7
would let `length()`, `print()` and `[[` be real generics rather than S3 methods bolted to
an R6 class. Worth revisiting before the first commit rather than after.

**Q2 — a general `stash_forget(stash, predicate)`.** `cache-model.md` §4.2 proves every
maintenance operation is one function. Exposing that general form would let a user write
`stash_forget(s, bytes > 1e8)` with the same data-masking as `stash_entries()`. It is
elegant and it is also a foot-gun with no undo. Probably yes, with the predicate required
rather than defaulted.

**Q3 — should `stash_get_many()` be the primitive?** One transaction for N keys is
strictly better than N transactions, and `stash_get()` could be
`stash_get_many()[[1]]`. That argues for the plural form being the real function. Against:
rule 5, and the scalar case is 99% of calls.

**Q4 — `expire` as seconds or as a constructor.** Both are currently accepted
(`expire = 3600` and `expire = expire_at(t)`), which is a small violation of rule 7. The
alternative is requiring `expire_in(3600)` everywhere, which is more consistent and more
typing. Undecided.

---

# 16. Later: the typed layer

When the datasets of `dastash-design.md` arrive (`design.md` §17), they extend this surface
rather than replacing it — a dataset is a stash plus a schema, and its verbs are the same
verbs with a key that is checked:

```r
prices <- dataset(
  "prices",
  stash = s,
  keys  = list(date = key_date(), exchange = key_character()),
  produce = \(key) fetch_prices(key$exchange, key$date)
)

ds_get(prices, date = as.Date("2026-08-29"), exchange = "XSWX")
ds_find(prices, exchange == "XSWX")
ds_entries(prices)
```

`ds_find()` is `stash_entries()` with the fibres of `cache-model.md` §9.3 available as real
columns — which is the whole point of declaring a schema, and the one thing the untyped
functional API above cannot offer.
