# dastash: A Persistent Disk Cache Shared Between Processes

A persistent, size-bounded cache that several R processes on one machine
can share, in the style of the Python 'diskcache' library. Keys map to
values that outlive the session, expire on a clock, carry tags for bulk
invalidation, and are culled when the cache grows past a limit. Metadata
and small values live in a transactional 'libmdbx' database through the
'mdbx' package; larger values are stored as content-addressed files.

## See also

Useful links:

- <https://pedrobtz.github.io/dastash/>

- <https://github.com/pedrobtz/dastash>

- Report bugs at <https://github.com/pedrobtz/dastash/issues>

## Author

**Maintainer**: Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]

Authors:

- Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]
