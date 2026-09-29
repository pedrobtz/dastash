# dastash key encoding, version 1

`KEY_ENCODING_VERSION = 1`. Normative. Every store records the version it was written
with, and `tests/testthat/golden/key-vectors.csv` freezes the examples below and many
more. A change to any rule here is version 2, never an edit to version 1.

The encoding maps an R value to a **canonical text**, a UTF-8 string. Two values are the
same key exactly when their canonical texts are byte-identical. The text is what the
store orders, prefix-scans and prints; its SHA-256 is the key hash.

## 1. Top level

| Input | Canonical text |
|---|---|
| A `dastash_key` | the text it carries |
| A character vector of length 1, not `NA`, without names, whose UTF-8 text does not start with an opener (§5) | that text, unchanged |
| Anything else | the value encoding of §2 |

`stash_key(...)` with one unnamed argument is that argument's key. With several
arguments, or any named ones, it is the key of `list(...)` — which must then be all
named or all unnamed.

## 2. Values

```text
value := "~"                                           NULL
       | tag ":" payload                               atomic, length 1, no names
       | tag "[" [ payload ("," payload)* ] "]"        atomic, length != 1, no names
       | tag "{" name "=" payload ("," name "=" payload)* "}"   atomic with names
       | "{" name "=" value ("," name "=" value)* "}"   list with names
       | "(" [ value ("," value)* ] ")"                list without names; empty list
       | "D{" [ name "=" value ("," name "=" value)* ] "}"  data frame
name  := escaped
```

- A **named list** and a **data frame** write their elements sorted by name, comparing
  the names' UTF-8 bytes (C locale). A repeated name is invalid.
- A **named atomic vector** keeps its elements in order, since order is part of a
  vector's value. Repeated names are allowed.
- Names are **all or none**: an empty or `NA` name among others is invalid.
- A list of length 0, named or not, is `()`.
- A **data frame** is its columns, as a named list, behind `D`. Row names and the row
  count are not written; each column is a value.
- A `dastash_key` inside a value is invalid: nest its values instead.

## 3. Atomic types

| R type or class | Tag | Payload of one element |
|---|---|---|
| factor | `e` | the label, escaped. Levels not present are not identity |
| `Date` | `d` | `YYYY-MM-DD` of the whole day (fractional days are floored); infinite dates are invalid |
| `POSIXct` | `t` | `YYYY-MM-DDTHH:MM:SS.ffffffZ` in UTC, rounded to the microsecond, always six digits; `tzone` is not identity; infinite times are invalid |
| `POSIXlt` | `t` | converted to `POSIXct` first |
| `difftime` | `u` | the number of seconds, as a double payload (below); `units` are not identity |
| `integer64` | `i` | decimal |
| character | `s` | the UTF-8 text, escaped |
| integer | `i` | decimal |
| double | `i` if every element is a whole number within ±2⁵³ or `NA` (not `NaN`), else `f` | see below |
| logical | `l` | `T` or `F` |
| raw | `r` | two lower-case hex digits |

`NA` of any type is `!`. **Doubles**: a whole number within ±2⁵³ is written in decimal,
with `-0` as `0`; `Inf`, `-Inf` and `NaN` are written as those words; any other value is
an exact hexadecimal float: `[-]0x1.<hex>p<exp>` for a normal number and
`[-]0x0.<hex>p-1022` for a subnormal, with `<hex>` the 52-bit fraction in lower-case hex,
trailing zeros dropped, and the `.` dropped when nothing is left. `<exp>` is signed
decimal, with `+` for zero and above. This is C99's `%a`, computed from the IEEE-754
bits so that it does not depend on the platform's C library. So `1L`, `1`, `-0` and
`bit64::as.integer64(1)` are all `i:1`, and `0.1` is `f:0x1.999999999999ap-4`.

The encoding is exact for the double it is given, and says nothing about how that double
was made. R's parser can turn one decimal literal into different doubles on different
platforms: on macOS arm64, where R has no extended-precision arithmetic to parse with,
`1e300` is one unit in the last place away from the correctly rounded value it is
elsewhere, and so a different key. A hexadecimal literal such as
`0x1.7e43c8800759cp+996` parses exactly everywhere, which is why the golden vectors use
one.

## 4. Escaping

In a payload or a name, each of these bytes is written `%XX` with upper-case hex:

```text
%  ,  =  [  ]  {  }  (  )  :  !  ~      and every byte 0x01-0x1F, and 0x7F
```

Nothing else is escaped: other ASCII and all non-ASCII UTF-8 bytes are written as they
are, so typical payloads stay legible. Text at the top level (§1) is never escaped.

## 5. Openers

A top-level string that starts with any of these is encoded as a character value,
`s:` followed by the escaped text, so it cannot be mistaken for an encoded value or a
digested key:

```text
~    #    {    (    D{    and    <tag>:  <tag>[  <tag>{    for <tag> in  s i f l r d t u e
```

## 6. Attributes

Only `names`; `class` for factor, `Date`, `POSIXct`, `POSIXlt`, `difftime`,
`integer64` and `data.frame`; `levels`; `tzone`; and `units` are read. Every other
attribute and class is ignored: a matrix is its elements, and `I(1:3)` is `1:3`.

## 7. Not keys

Functions, environments, symbols and calls, external pointers, S4 objects, complex
numbers, and strings that are not valid UTF-8 (or are marked `"bytes"`) raise
`dastash_key_invalid`.

## 8. Storage form and hash

The key hash is the SHA-256 of the canonical text's UTF-8 bytes, as 64 lower-case hex
characters.

A canonical text of at most `KEY_MAX = 512` bytes is stored as itself. A longer one is
stored as `#` followed by its key hash, 65 bytes; the record keeps the full text when it
is at most `CANON_KEEP_MAX = 4096` bytes, and otherwise its first bytes up to 256 (never
splitting a character) and its length. Since `#` is an opener, no key's canonical text
starts with `#`, so a digested key cannot collide with a stored text.
