source("lib.R")
if (nzchar(Sys.getenv("HOSTILE"))) options(OutDec = ",", scipen = -5, digits = 3)
k <- function(x) tryCatch(cache_key_chr(x), error = function(e) paste0("<", class(e)[1], "> ", conditionMessage(e)[1]))
lat <- "caf\xe9"; Encoding(lat) <- "latin1"
u <- "café"
vals <- list(
  ab = c("a","bbb"), fac = factor(c("a","bbb")), fac1 = factor("a"), facNA = factor(c("a",NA)), facNAlev = factor(c("a",NA), exclude=NULL),
  i = 5L, d7 = 123456.7891, d8=1234567.1, big31 = 2^31, big31p = 2^31+1, big53 = 2^53, big53p = 2^53+2, e15=1e15, e5=1e5, e22=1e22, i1e5=100000L,
  neg0 = -0, tiny = 5e-324, minnorm=2.2250738585072014e-308, max=.Machine$double.xmax, pt1 = 0.1, mpt1=-0.1, half=0.5, one5=1.5,
  T = TRUE, NAl = NA, NAi = NA_integer_, NAr = NA_real_, NAc = NA_character_, nan = NaN, inf = Inf, mInf=-Inf, mixNaN = c(1,NaN), mixNA=c(1,NA), mixInf=c(1,Inf),
  NULL0 = NULL, c0 = character(0), i0 = integer(0), d0=double(0), l0 = logical(0), r0=raw(0), list0 = list(), nlist0 = setNames(list(), character(0)),
  date = as.Date("2026-08-29"), datefrac = as.Date(20000.7), dateneg = as.Date(-0.5), dateint = structure(20000L, class="Date"), dateNA = as.Date(NA), date0001 = as.Date("0001-01-01"), date10000 = as.Date(2932897), dateBC = as.Date(-800000),
  ct = as.POSIXct("2026-08-29 12:34:56.789", tz="UTC"), ctNY = as.POSIXct("2026-08-29 12:34:56", tz="America/New_York"), ctfrac = .POSIXct(0.9999996, "UTC"), ctneg = .POSIXct(-0.5, "UTC"), ctneg2 = .POSIXct(-1e-7, "UTC"),
  ctint = .POSIXct(1L, "UTC"), ctNA = as.POSIXct(NA), lt = as.POSIXlt("2026-08-29 12:34:56", tz="Europe/Zurich"), ctbig = .POSIXct(1e11,"UTC"), ctbig2=.POSIXct(253402300800,"UTC"), ctold=.POSIXct(-62135596800-86400*400,"UTC"),
  dt = as.difftime(1, units="hours"), dtm = as.difftime(90, units="mins"), dtf = as.difftime(0.1, units="secs"), dtw = as.difftime(c(1,NA), units="weeks"),
  lst = list(1, "a"), nlst = list(b=1, a="x"), duplst = list(a=1, a=2), partlst = list(a=1, 2), emptynm = setNames(list(1,2), c("","")), NAnm = setNames(list(1,2), c("a",NA)),
  nvec = c(a=1, b=2), nvecdup = c(a=1, a=2), nvec1 = c(a=1), nvecpart = c(a=1, 2), nchr = c(a="x"),
  u = u, lat = lat, nl = "a\nb", lvec = c(lat, "x"), uvec=c(u,"x"), esc = c("a,b", "a=b", "%", "!", "~", ":"), del = "a\x7fb", tab = c("\t","x"),
  op1 = "s:abc", op2 = "{a}", op3 = "~", op4 = "#abc", op5="D{", op6 = "(x", op7 = "e[", op8="i:1", op9 = "D", op10="s", op11="x:1", op12=" s:1", empty = "",
  raw = as.raw(c(0, 255)), raw1 = as.raw(10), cplx = 1i, fn = sum, env = globalenv(), sym = quote(x), call = quote(f(x)), form = y ~ x,
  mat = matrix(1:4, 2), matdn = matrix(1:4, 2, dimnames=list(c("a","b"),NULL)), I = I(1:3), Istr = I("abc"),
  df = data.frame(b=1:2, a=c("x","y")), df0 = data.frame(), dfrn = data.frame(a=1, row.names="r"), dfnest = data.frame(a=I(list(1,2))),
  nv = numeric_version("1.2.3"), bytes = {b <- "a\xff"; Encoding(b) <- "bytes"; b}, bad = "a\xff",
  nested = list(a=list(b=NULL, c=list()), d=c(x=TRUE)), listnull = list(NULL), listnm_esc = setNames(list(1), "a=b,c"),
  nmNAatomic = setNames(1:2, c("a", NA)), nmutf = setNames(1, u), nmlat = setNames(1, lat)
)
if (requireNamespace("bit64", quietly=TRUE)) { vals$i64 <- bit64::as.integer64("9007199254740993"); vals$i64v <- bit64::as.integer64(c(1,NA)); vals$i64one <- bit64::as.integer64(1) }
out <- vapply(vals, k, "")
# vals drops NULL0; add
out <- c(out, NULL0 = k(NULL))
for (n in names(out)) cat(sprintf("%-10s %s\n", n, encodeString(out[[n]])))
saveRDS(out, Sys.getenv("OUT", "p01.rds"))
