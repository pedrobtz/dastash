# dastash

<!-- badges: start -->
[![R-CMD-check](https://github.com/pedrobtz/dastash/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/pedrobtz/dastash/actions/workflows/R-CMD-check.yaml)
[![coverage](https://raw.githubusercontent.com/pedrobtz/dastash/main/.github/badges/coverage.svg)](https://github.com/pedrobtz/dastash/actions/workflows/coverage.yaml)
<!-- badges: end -->

dastash is a persistent disk cache that several R processes on one machine can share, in
the style of Python's [diskcache](https://github.com/grantjenks/python-diskcache). Keys map
to values that outlive the session, expire on a clock, carry tags for bulk invalidation,
and are culled when the cache grows past a size limit. Metadata and small values live in a
transactional [libmdbx](https://libmdbx.dqdkfa.ru/) database through the
[mdbx](https://github.com/pedrobtz/mdbx) package; larger values are content-addressed
files.

**Status:** under construction, heading for a first CRAN release (0.1.0). Nothing is usable
yet.

## Installation

You can install the development version of dastash from
[GitHub](https://github.com/pedrobtz/dastash) with:

``` r
# install.packages("pak")
pak::pak("pedrobtz/dastash")
```
