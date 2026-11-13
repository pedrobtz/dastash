source("lib.R")
p <- function(label, x) cat(sprintf("%-28s %s\n", label, substr(paste(capture.output(print(x)), collapse=" / "), 1, 400)))
s <- cache(tempfile("c-"))
set.seed(1)
long1 <- paste0("ab", strrep("L", 600)); long2 <- paste0("b", strrep("M", 700)); long3 <- paste0("a", strrep("N", 5000))
keys <- c("", "a", "ab", "abc", "a/b", "b", "B", "é", "ée", "a\nb", "a b", "zz", "a%", "aé", "A", "0", "10", "9", long1, long2, long3)
for (k in keys) cache_set(s, k, 1)
cache_set(s, list(n=1), 1); cache_set(s, 1:3, 1); cache_set(s, "{x", 1); cache_set(s, c(a=1), 1); cache_set(s, NULL, 1)
cache_set(s, "aexp", 1, expire=-1); cache_set(s, "bexp", 1, expire=-1)
all <- cache_keys(s)
p("all", nchar(all)); p("all short", all[nchar(all) < 70])
p("sorted bytewise?", identical(all[nchar(all)<500 & !startsWith(all,"#")], sort(all[nchar(all)<500& !startsWith(all,"#")], method="radix")))
p("count vs keys", c(cache_count(s), length(all), nrow(cache_entries(s)), cache_stats(s)$count, length(s)))
texts <- all  # shown texts
brute <- function(prefix=NULL, start=NULL, n=Inf) { k <- texts; if (!is.null(prefix)) k <- k[startsWith(k, prefix)]; k }
for (pf in c("", "a", "ab", "b", "é", "a\n", "{", "s:", "i", "#", "zzz", "abL", "aN", "\xc3")) {
  got <- tr(cache_keys(s, prefix = pf)); exp <- brute(pf)
  ok <- is.character(got) && setequal(got, exp)
  if (!ok) { p(paste("PREFIX DIFF", encodeString(pf)), list(got=substr(got,1,20), exp=substr(exp,1,20))) }
  ge <- tr(cache_entries(s, prefix = pf)$key)
  if (!identical(ge, got)) p(paste("ENTRIES!=KEYS", encodeString(pf)), list(substr(ge,1,20), substr(got,1,20)))
}
# n
for (n in c(0, 1, 3, 5, 100)) for (pf in list(NULL, "a", "ab")) {
  got <- cache_keys(s, prefix=pf, n=n); full <- cache_keys(s, prefix=pf)
  if (!identical(got, head(full, n))) p(paste("N DIFF", n, pf), list(substr(got,1,20), substr(head(full,n),1,20)))
}
# start
for (st in c("", "a", "ab", "abc", "b", "c", "~", "#", "é", "aexp", "zzzz", "{")) for (pf in list(NULL, "a", "b", "")) for (n in c(Inf, 2)) {
  got <- tr(cache_keys(s, prefix=pf, start=st, n=n)); full <- cache_keys(s, prefix=pf)
  # expected: stored-key order at or after start
  stored <- vapply(full, function(k) dazcache:::store_key(cache_key_text(k))$stored, "")
  exp <- unname(full[vapply(stored, function(k) order(c(st,k), method="radix")[1]==1, NA)]); exp <- head(exp, n)
  if (!identical(got, exp)) p(paste("START DIFF st=", encodeString(st), "pf=", pf, "n=", n), list(got=substr(got,1,20), exp=substr(exp,1,20)))
}
p("start key obj", tr(cache_keys(s, start=cache_key(list(n=1)), n=3)))
p("start long text", tr(substr(cache_keys(s, start=long1, n=2),1,10)))
p("start num", tr(cache_keys(s, start=1)))
p("start NA", tr(cache_keys(s, start=NA_character_)))
p("prefix NA", tr(cache_keys(s, prefix=NA_character_)))
p("prefix 2", tr(cache_keys(s, prefix=c("a","b"))))
p("prefix key obj", tr(cache_keys(s, prefix=cache_key("a"))))
lat <- "\xe9"; Encoding(lat) <- "latin1"
p("prefix latin1", tr(cache_keys(s, prefix=lat)))
p("start latin1", tr(substr(cache_keys(s, start=lat),1,10)))
p("entries prefix latin1", tr(cache_entries(s, prefix=lat)$key))
p("evict prefix latin1", tr({cache_evict(s, prefix=lat); cache_keys(s, prefix="é")}))
p("n 2.5", tr(cache_keys(s, n=2.5))); p("n '2'", tr(cache_keys(s, n="2"))); p("n 2L", tr(cache_keys(s, n=2L))); p("n NULL", tr(cache_keys(s, n=NULL)))
p("paging loop", {out <- character(); st <- NULL; repeat { pg <- cache_keys(s, start=st, n=4); if (!is.null(st)) pg <- pg[-1]; if (!length(pg)) break; out <- c(out, pg); st <- cache_key_text(pg[length(pg)]) }; c(length(out), length(cache_keys(s)), anyDuplicated(out))})
p("paging loop str start", tr({out <- character(); st <- NULL; repeat { pg <- cache_keys(s, start=st, n=4); if (!is.null(st)) pg <- pg[-1]; if (!length(pg)) break; out <- c(out, pg); st <- pg[length(pg)] }; c(length(out), length(cache_keys(s)), anyDuplicated(out))}))
# evict by prefix, then listing
p("evict prefix a", tr({cache_evict(s, prefix="a"); substr(cache_keys(s),1,12)}))
p("count after", c(cache_count(s), length(cache_keys(s))))
p("expire()", tr({cache_expire(s); c(cache_count(s), length(cache_keys(s)))}))
p("clear", tr({cache_clear(s); c(cache_count(s), length(cache_keys(s)), cache_stats(s)$bytes_inline)}))
