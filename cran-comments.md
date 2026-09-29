## Submission

This is the first submission of dastash.

## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new release.

## Notes for the reviewer

* `Depends: R (>= 4.5.0)`: the package hashes with `tools::sha256sum()`,
  which R 4.5.0 added.

* Examples, tests and vignettes write only under `tempdir()`, and remove
  what they create.

* Tests that start several R processes (with 'callr' or `fork()`) to check
  behaviour across processes are skipped on CRAN, to stay within its time and
  CPU limits. They run in the package's continuous integration.

* There are no published references describing the methods in this package.
  It follows the design of the 'Python' library 'diskcache'
  (<https://github.com/grantjenks/python-diskcache>).
