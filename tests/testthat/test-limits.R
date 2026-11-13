# Every size limit at limit - 1, limit and limit + 1, on every path that
# reaches it, in the unit it is counted in (correctness.md, "Straddle every
# threshold"). A test far from a limit passes an off-by-one; these do not.

bytes_of <- function(x) nchar(x, type = "bytes")

test_that("KEY_MAX counts UTF-8 bytes, on every path a key takes (#84)", {
  s <- local_cache()
  keys <- c(
    k511 = strrep("a", 511),
    k512 = strrep("é", 256),
    k513 = paste0("x", strrep("é", 256))
  )
  expect_identical(unname(bytes_of(keys)), c(511L, 512L, 513L))
  expect_identical(unname(nchar(keys)), c(511L, 256L, 257L))
  stored <- vapply(keys, function(k) store_key(k)$stored, "")
  expect_identical(unname(stored[1:2]), unname(keys[1:2]))
  expect_identical(unname(stored[[3]]), paste0("#", cache_key_hash(keys[[3]])))

  cache_set(s, keys[["k511"]], 1)
  cache_mset(s, list(2, 3) |> stats::setNames(keys[2:3]))
  expect_identical(cache_mget(s, keys), list(1, 2, 3) |> stats::setNames(keys))
  expect_setequal(cache_keys(s), keys)
  expect_identical(cache_keys(s, prefix = "xé"), keys[["k513"]])
  expect_identical(cache_keys(s, prefix = "éé"), keys[["k512"]])
  cache_delete(s, keys[2:3])
  expect_identical(cache_keys(s), keys[["k511"]])

  # A memoised call's key: `m/v1/{x=s:` and `}` around the argument.
  m <- cache_memoise(function(x) nchar(x), s, name = "m")
  for (n in c(501L, 502L)) {
    arg <- strrep("b", n)
    expect_identical(m(arg), n)
    text <- cache_memoise_key(m, arg)
    expect_identical(bytes_of(text), n + 11L)
    expect_identical(store_key(text)$stored == text, n + 11L <= 512L)
    expect_identical(m(arg), n)
    expect_true(text %in% cache_keys(s))
  }
})

test_that("CANON_KEEP_MAX keeps a digested key's text up to 4096 bytes and no further (#85)", {
  s <- local_cache()
  texts <- c(
    t4095 = strrep("a", 4095),
    t4096 = strrep("é", 2048),
    t4097 = paste0("x", strrep("é", 2048))
  )
  expect_identical(unname(bytes_of(texts)), c(4095L, 4096L, 4097L))
  for (i in 1:2) {
    st <- key_storage(texts[[i]])
    expect_identical(st$key_text, texts[[i]])
    expect_null(st$key_preview)
  }
  st <- key_storage(texts[[3]])
  expect_null(st$key_text)
  expect_identical(st$key_bytes, 4097L)
  for (k in texts) cache_set(s, k, k)
  listed <- cache_keys(s)
  expect_true(all(texts[1:2] %in% listed))
  expect_true(paste0("#", cache_key_hash(texts[[3]])) %in% listed)
  for (k in texts) expect_identical(cache_get(s, k), k)
})

test_that("a preview keeps 256 bytes and never splits a character (#129)", {
  tail <- strrep("z", 5000)
  cases <- list(
    list(head = "", cut = 256L),
    # A 2-byte character ending at byte 256, and one that would straddle it.
    list(head = paste0(strrep("a", 254), "é"), cut = 256L),
    list(head = paste0(strrep("a", 255), "é"), cut = 255L),
    # A 4-byte character ending at byte 256, and one that would straddle it.
    list(head = paste0(strrep("a", 252), "\U0001F600"), cut = 256L),
    list(head = paste0(strrep("a", 253), "\U0001F600"), cut = 253L)
  )
  for (case in cases) {
    text <- paste0(case$head, tail)
    preview <- key_storage(text)$key_preview
    label <- paste("head of", bytes_of(case$head), "bytes")
    expect_identical(bytes_of(preview), case$cut, label = label)
    expect_true(validUTF8(preview), label = label)
    expect_identical(charToRaw(preview), charToRaw(text)[seq_len(case$cut)], label = label)
  }
  # A prefix matches a preview-only key while it fits in the preview: 255 and
  # 256 bytes do, 257 does not (?cache_keys).
  s <- local_cache()
  text <- strrep("p", 5000)
  cache_set(s, text, 1)
  for (n in c(255L, 256L, 257L)) {
    expect_identical(length(cache_keys(s, prefix = strrep("p", n))), as.integer(n <= 256L), label = n)
  }
})

test_that("inline_max makes a file from exactly inline_max encoded bytes, on every write path (#87)", {
  n <- 64L
  s <- local_cache(inline_max = n, codec = codec_raw())
  v <- function(len) as.raw(seq_len(len) %% 256L)
  inline <- function(key) cache_entries(s, prefix = key)$inline
  sizes <- c(n - 1L, n, n + 1L)
  for (len in sizes) {
    cache_set(s, paste0("set", len), v(len))
    cache_mset(s, stats::setNames(list(v(len)), paste0("mset", len)))
    cache_add(s, paste0("add", len), v(len))
  }
  m <- cache_memoise(function(len) v(len), s, name = "memo", codec = codec_raw())
  for (len in sizes) m(len)
  for (path in c("set", "mset", "add")) {
    expect_identical(
      vapply(sizes, function(len) inline(paste0(path, len)), logical(1)),
      c(TRUE, FALSE, FALSE),
      label = path
    )
  }
  memo <- cache_entries(s, prefix = "memo/")
  expect_identical(memo$inline[order(memo$bytes)], c(TRUE, FALSE, FALSE))
  for (len in sizes) expect_identical(cache_get(s, paste0("set", len)), v(len))

  # Counters are always inline, even when nothing else is.
  z <- local_cache(inline_max = 0)
  cache_incr(z, "c")
  cache_set(z, "x", as.raw(1))
  expect_identical(cache_entries(z, prefix = "c")$inline, TRUE)
  expect_identical(cache_entries(z, prefix = "x")$inline, FALSE)
  expect_identical(nrow(cache_check(z, hash = TRUE)), 0L)
})

test_that("size_limit holds exactly: full is not over, one byte over evicts the oldest (#88)", {
  ten <- function(i) as.raw(rep(i, 10))
  for (path in c("set", "mset", "incr")) {
    s <- local_cache(size_limit = 30, codec = codec_raw())
    for (i in 1:3) cache_set(s, paste0("k", i), ten(i))
    expect_identical(held(s), 30)
    expect_identical(cache_stats(s)$evictions, 0)
    switch(
      path,
      set = cache_set(s, "over", as.raw(1)),
      mset = cache_mset(s, list(over = as.raw(1))),
      # A counter is 8 bytes: 38 held, so the oldest goes and 28 remain.
      incr = cache_incr(s, "over")
    )
    expect_identical(cache_stats(s)$evictions, 1, label = path)
    expect_false(cache_has(s, "k1"), label = path)
    expect_true(all(cache_has(s, c("k2", "k3", "over"))), label = path)
    expect_lte(held(s), 30)
  }

  # A blob held by two keys counts once.
  b <- local_cache(inline_max = 100)
  x <- runif(100)
  cache_set(b, "one", x)
  size <- cache_entries(b)$bytes
  cache_set(b, "two", x)
  expect_identical(held(b), size)
  expect_identical(cache_stats(b)$bytes_blob, size)
})
