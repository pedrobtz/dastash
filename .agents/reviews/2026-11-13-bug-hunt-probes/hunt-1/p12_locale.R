source("lib.R")
p <- function(label, x) cat(sprintf("%-28s %s\n", label, substr(paste(capture.output(print(x)), collapse=" / "), 1, 500)))
d <- Sys.getenv("DZDIR"); phase <- Sys.getenv("PHASE")
s <- cache(d)
u <- "café"; lat <- iconv(u, "UTF-8", "latin1"); Encoding(lat) <- "latin1"
raw_u <- rawToChar(as.raw(c(0x63,0x61,0x66,0xc3,0xa9)))  # unmarked utf-8 bytes
raw_l <- rawToChar(as.raw(c(0x63,0x61,0x66,0xe9)))        # unmarked latin1 bytes
p("locale", c(Sys.getlocale("LC_CTYPE"), l10n_info()$`UTF-8`))
if (phase == "write") {
  cache_set(s, u, "v-utf8", tags = u); cache_set(s, list(name = u), u); cache_set(s, paste0(u, "/long", strrep("x", 600)), 1)
  cache_set(s, "txt", c(u, lat))
} 
kk <- function(x) tr(paste(as.character(charToRaw(cache_key_chr(x))), collapse=""))
p("key u", kk(u)); p("key lat", kk(lat)); p("key raw_u", kk(raw_u)); p("key raw_l", kk(raw_l)); p("key list raw_l", kk(list(raw_l)))
p("get u", tr(cache_get(s, u))); p("get lat", tr(cache_get(s, lat))); p("get raw_u", tr(cache_get(s, raw_u, default = "MISS"))); p("get raw_l", tr(cache_get(s, raw_l, default = "MISS")))
ks <- cache_keys(s); p("keys enc", Encoding(ks)); p("keys bytes ok", u %in% ks || enc2utf8(u) %in% enc2utf8(ks))
p("prefix u", tr(length(cache_keys(s, prefix = u)))); p("prefix lat", tr(length(cache_keys(s, prefix = lat)))); p("prefix raw_l", tr(length(cache_keys(s, prefix = raw_l)))); p("prefix raw_u", tr(length(cache_keys(s, prefix = raw_u))))
p("start lat", tr(length(cache_keys(s, start = lat))))
p("entries prefix lat", tr(nrow(cache_entries(s, prefix = lat)))); p("entries tag lat", tr(nrow(cache_entries(s, tag = lat)))); p("entries tag raw_l", tr(nrow(cache_entries(s, tag = raw_l))))
p("entries tags enc", tr(Encoding(unlist(cache_entries(s)$tags))))
p("structured get", tr(charToRaw(cache_get(s, list(name = lat)))))
p("value txt", tr({v <- cache_get(s, "txt"); list(Encoding(v), lapply(v, charToRaw))}))
p("mget names", tr(Encoding(names(cache_mget(s, c(u, "txt"))))))
p("roundtrip key_text", tr(all(vapply(ks, function(k) cache_has(s, cache_key_text(k)), NA))))
p("nf msg", tr(conditionMessage(tryCatch(cache_get(s, paste0(u, "zz")), error = function(e) e))))
p("memo key", tr({f <- function(x) x; m <- cache_memoise(f, s, name = "f"); kk2 <- cache_memoise_key(m, lat); paste(charToRaw(kk2), collapse = "")}))
p("cachem prefix lat", tr({cm <- as_cachem(s, prefix = paste0(lat, "-c/")); cm$set("a", 1); cm$keys()}))
if (phase != "write") p("evict prefix lat", tr({cache_evict(s, prefix = lat); length(cache_keys(s))}))
