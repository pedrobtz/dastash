# The whole store against a model: an R list of what each key should read as.
# Random operations go to both; after every step each key's value, the key
# list and the count must agree. The invariant checks elsewhere hold for a
# store that loses a write or brings a key back; this does not (#74).
#
# Expiry needs no clock: an entry either expires at once (`expire = 0`) or not
# for an hour, and both are exact in the model. An expired entry reads as
# absent but is still counted until something reclaims it, so the model keeps
# those too, as `ghost`: key to tags.

model_run <- function(seed, steps) {
  set.seed(seed)
  s <- local_cache(inline_max = 200)
  miss <- "<MISS>"
  keys <- c("a", "b", "c", "p/1", "p/2", "p/10", "q", strrep("long", 150), "é/x")
  values <- list(1, "two", 1:3, as.raw(1:10), runif(100), runif(100), letters, NULL)
  big <- values[[5]] # stored under several keys: one shared blob
  tags_pool <- c("t1", "t2")
  model <- list()
  ghost <- list()
  gone <- function(k) {
    model[[k]] <<- NULL
    ghost[[k]] <<- NULL
  }
  pick <- function(x) x[[sample.int(length(x), 1)]]
  value <- function() if (runif(1) < 0.25) big else pick(values[!vapply(values, is.null, TRUE)])
  tags <- function() if (runif(1) < 0.4) sample(tags_pool, sample.int(2, 1)) else NULL
  expire <- function() pick(list(NULL, NULL, 3600, 0))
  m_set <- function(k, v, ex, tg) {
    gone(k)
    if (identical(ex, 0)) {
      ghost[[k]] <<- tg %||% character()
    } else {
      model[[k]] <<- list(value = v, tags = tg %||% character(), counter = FALSE)
    }
  }
  # One operation on the cache and the model. Returns a description.
  op <- function() {
    k <- pick(keys)
    kind <- pick(c("set", "set", "set", "mset", "add", "delete", "pop", "incr", "touch", "expire", "evict_tag", "evict_prefix", "transact", "fail"))
    switch(
      kind,
      set = {
        v <- value(); ex <- expire(); tg <- tags()
        cache_set(s, k, v, expire = ex, tags = tg)
        m_set(k, v, ex, tg)
      },
      mset = {
        ks <- unique(c(k, pick(keys)))
        vs <- lapply(ks, function(i) value())
        cache_mset(s, stats::setNames(vs, ks))
        for (i in seq_along(ks)) m_set(ks[[i]], vs[[i]], NULL, NULL)
      },
      add = {
        v <- value()
        added <- cache_add(s, k, v)
        expect_identical(added, is.null(model[[k]]), label = paste("add", k))
        if (added) m_set(k, v, NULL, NULL)
      },
      delete = {
        cache_delete(s, k)
        gone(k)
      },
      pop = {
        got <- cache_pop(s, k, default = miss)
        want <- if (is.null(model[[k]])) miss else model[[k]]$value
        expect_identical(got, want, label = paste("pop", k))
        # A pop of an expired entry is a miss and leaves it for reclaiming.
        model[[k]] <<- NULL
      },
      incr = {
        by <- sample(-3:3, 1)
        m <- model[[k]]
        if (!is.null(m) && !m$counter) {
          expect_error(cache_incr(s, k, by = by), class = "dazcache_type_error")
        } else {
          start <- if (is.null(m)) 0 else m$value
          expect_identical(cache_incr(s, k, by = by), start + by, label = paste("incr", k))
          ghost[[k]] <<- NULL
          model[[k]] <<- list(value = start + by, tags = m$tags %||% character(), counter = TRUE)
        }
      },
      touch = {
        ex <- pick(list(3600, 0))
        cache_touch(s, k, ex)
        if (identical(ex, 0) && !is.null(model[[k]])) {
          ghost[[k]] <<- model[[k]]$tags
          model[[k]] <<- NULL
        }
      },
      expire = {
        cache_expire(s)
        ghost <<- list()
      },
      evict_tag = {
        tg <- pick(tags_pool)
        cache_evict(s, tag = tg)
        for (i in names(model)) if (tg %in% model[[i]]$tags) model[[i]] <<- NULL
        for (i in names(ghost)) if (tg %in% ghost[[i]]) ghost[[i]] <<- NULL
      },
      evict_prefix = {
        cache_evict(s, prefix = "p/")
        for (i in c(names(model), names(ghost))) if (startsWith(i, "p/")) gone(i)
      },
      transact = {
        v <- value(); k2 <- pick(keys)
        cache_transact(s, {
          cache_set(s, k, v)
          cache_delete(s, k2)
        })
        m_set(k, v, NULL, NULL)
        gone(k2)
      },
      fail = {
        v <- value()
        expect_error(cache_transact(s, {
          cache_set(s, k, v)
          stop("abandoned")
        }), "abandoned")
      }
    )
    paste(kind, k)
  }
  check <- function(step) {
    live <- names(model) %||% character()
    for (k in keys) {
      want <- if (is.null(model[[k]])) miss else model[[k]]$value
      expect_identical(cache_get(s, k, default = miss), want, label = paste0("step ", step, ": get ", substr(k, 1, 12)))
    }
    expect_setequal(cache_keys(s), live)
    expect_identical(cache_count(s), length(model) + length(ghost))
    for (tg in tags_pool) {
      have <- live[vapply(model, function(m) tg %in% m$tags, logical(1))]
      expect_setequal(cache_entries(s, tag = tg)$key, have)
    }
  }
  for (step in seq_len(steps)) {
    what <- op()
    check(paste(step, what))
    if (step %% 50 == 0) expect_identical(store_violations(s), character())

  }
  # An aborted block reaps the blobs it published, so nothing is left over,
  # not even an orphan.
  found <- cache_check(s, hash = TRUE)
  expect_identical(nrow(found), 0L, label = paste(seed, paste(found$kind, found$key, found$detail, collapse = "; ")))
  check("after repair")
}

test_that("the store reads as a model of it after every operation", {
  skip_on_cran()
  for (seed in c(74, 741, 7411)) model_run(seed, 250)
})
