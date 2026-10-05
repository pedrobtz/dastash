# dastash: Persistent Disk Cache Shared Between Processes

A persistent, size-bounded cache that several 'R' processes on one
machine can share, in the style of the 'Python' library 'diskcache'.
Keys map to values that outlive the session, expire on a clock, carry
tags for bulk invalidation, and are evicted when the cache grows past a
limit. Metadata and small values live in a transactional 'libmdbx'
database through the 'mdbx' package, and larger values are stored as
content-addressed files. Functions can be memoised across sessions and
processes, and the cache can be used through the 'cachem' interface.

## See also

Useful links:

- <https://pedrobtz.github.io/dastash/>

- <https://github.com/pedrobtz/dastash>

- Report bugs at <https://github.com/pedrobtz/dastash/issues>

## Author

**Maintainer**: Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]

Authors:

- Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]
