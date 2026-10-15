# nif-assets benchmarks

`bench/bench.jsl` times the package through its public modules: the path rules (`normalize`,
`isNifPath`, `texturePath`), a load order's models listed as targets, the check with its texture
lookups, the report cut down to what is shown, info, dump, the dry run of the fixes, the argument
list read, and every document the command line prints, in each format. The models are the suite's
two files (`all_types.nif`, every record type once, 16 KB; `random_objects.nif`, eight shapes,
233 KB), a Skyrim node spelled by hand, and 64 small ones built in the bench with `@nif`, written
to a data folder in scratch beside a folder of 4,096 empty files to list. A warm workload is
warmed up, sized to a batch of about a tenth of a second, and reported as the median of seven
batches with a full collection between them. A `cold:` workload is the median of seven fresh
processes running `bench/cold.jsl`, which is the command line run once, timed inside the script
from its first `require`: most of it is compiling the modules it loads. Every workload's answer
is compared with one pinned in the file: a count, or the checksum and length of the document.

```sh
jess run --capability filesystem.read --capability filesystem.write --capability process.spawn \
  --package jpk/nif-assets --package-path jpk jpk/nif-assets/bench/bench.jsl \
  <scratch> [filter] [jess binary] [package path]
```

Without the binary (and `process.spawn`) the cold workloads are skipped. A filter is parts
separated by `|`, any of which picks a workload by its name.

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, shared with other work while this ran
  (load average 1.4 to 3.4 over the run).
- Date: 2026-10-12.
- Binary: the verified release build of Jess on l3i 2.0.2 (Luau 0.742), the same one for both
  sides.
- Base: `eb3c691`, the package before the move, with this bench (the bench file as it is now,
  copied over the export: the cold workloads and the filter came later, and run against the old
  code as they are). Head: `ebf3680`.
- Protocol: the whole bench against an export of base, then against head, three times over, back
  to back under one lock; each cell is the median of its three runs. A difference under 5 percent
  is called no change.

| Workload | Base | Head | Base / head |
|---|---:|---:|---:|
| normalize 256 written paths | 128.09 µs | 79.17 µs | 1.62x |
| isNifPath over 4,096 keys | 710.34 µs | 162.05 µs | 4.38x |
| texturePath for 256 written paths | 995.09 µs | 441.33 µs | 2.25x |
| new + addBase over 4,096 keys | 2.20 ms | 1.17 ms | 1.88x |
| new + addVfsTarget for 64 models | 131.59 µs | 115.53 µs | 1.14x |
| check 67 models in a data folder | 5.37 ms | 5.41 ms | no change |
| checkBytes random_objects | 111.41 µs | 107.80 µs | no change |
| shown: 2,680 files down to collision | 5.69 ms | 698.98 µs | 8.14x |
| shown: 2,680 files, every file and finding | 6.84 ms | 994.64 µs | 6.88x |
| infoBytes all_types | 12.68 µs | 12.54 µs | no change |
| infoBytes random_objects | 173.00 µs | 167.34 µs | no change |
| info for 67 models in a data folder | 6.94 ms | 6.89 ms | no change |
| dump all_types | 507.57 µs | 473.78 µs | 1.07x |
| dump random_objects | 2.37 ms | 2.09 ms | 1.13x |
| dump random_objects, listed | 109.26 µs | 114.99 µs | no change |
| dump all_types, shapes named tri | 130.23 µs | 128.74 µs | no change |
| dump a Skyrim node | 31.74 µs | 30.91 µs | no change |
| fix 67 models, dry run | 3.70 ms | 3.67 ms | no change |
| parse 8 argument lists | 17.16 µs | 16.41 µs | no change |
| render check of 67 models as yaml | 19.59 ms | 18.86 ms | no change |
| render check of 67 models as json | 2.34 ms | 2.22 ms | 1.05x |
| render check of 67 models as toml | 3.67 ms | 3.50 ms | no change |
| render info of 67 models as yaml | 31.42 ms | 29.95 ms | no change |
| render info of 67 models as json | 3.84 ms | 3.78 ms | no change |
| render info of 67 models as toml | 5.83 ms | 5.72 ms | no change |
| render fix of 67 models as yaml | 2.77 ms | 2.66 ms | no change |
| render fix of 67 models as json | 346.92 µs | 336.18 µs | no change |
| render fix of 67 models as toml | 576.37 µs | 553.21 µs | no change |
| render dump of all_types as yaml | 5.34 ms | 4.39 ms | 1.22x |
| render dump of all_types as json | 3.01 ms | 2.94 ms | no change |
| render dump of all_types as toml | 3.82 ms | 3.69 ms | no change |
| render dump of random_objects as yaml | 444.60 ms | 182.07 ms | 2.44x |
| render dump of random_objects as json | 83.81 ms | 79.56 ms | 1.05x |
| render dump of random_objects as toml | 92.38 ms | 87.80 ms | 1.05x |
| check command: sources, check, shown, YAML | 29.88 ms | 28.13 ms | 1.06x |
| cold: help | 229.12 ms | 218.03 ms | 1.05x |
| cold: check of 67 models | 256.12 ms | 254.51 ms | no change |
| cold: dump of random_objects | 670.32 ms | 420.43 ms | 1.59x |

The rows at 1.05x to 1.07x sit on the edge of what three runs on a shared machine resolve. Nothing
on the way to `help`, or to a check's or a dump's JSON and TOML, changed, so those are no change
read generously; `dump all_types` and the check command do run code that changed, and may be
what they say.

The table was read again on review, by the same protocol: three rounds, base and head alternated
under one lock, load average 1.6 to 2.8. The rows that moved came out the same within noise:
`normalize` 1.59x, `isNifPath` 4.22x, `texturePath` 2.22x, `addBase` 1.88x, `addVfsTarget`
1.10x, `shown` 8.02x and 6.29x, `dump random_objects` 1.10x, a dump as YAML 1.14x for
`all_types` and 2.30x for `random_objects`, and the cold dump 1.57x. None of the rows at 1.05x to
1.07x did: every one was within 5 percent the second time, `dump all_types` (511 against 514 µs)
and the check command (30.1 against 29.5 ms) among them, so all of them are no change. Two rows
crossed the line the other way and are noise as well: `check 67 models` read 1.07x, and the fix
as JSON 0.95x with nothing on its path changed.

Each commit's share was read again too, three rounds against the commit before it with the bench
filtered to the row: the file name by `bytes.rfind` 1.67x on `texturePath`, and the extension and
directory by their bytes 1.08x; `3258729` 0.72x on `normalize`, and `df93927` 2.18x over that,
with 1.27x on `texturePath`; the sort 1.22x on `addBase`; numbers not spelled to be measured 1.73x
on the YAML dump of `random_objects`, and the digits read off their places 1.24x more; the view
loop 1.11x on `dump random_objects`. These are a second reading of the shares given below, not a
correction of them: both are three rounds or fewer on a shared machine.

What moved, and why. None of it is the dialect: a comprehension is the loop it replaces, and this
package owns no buffer of numbers for l3i's data plane to take. It is two `@dream/bytes` calls,
byte tests where strings were made to be compared, and work that was being done twice. Where a
commit's own share is given, it is from runs of that commit against the one before it (one to
three rounds under the same lock), not from the table.

- **`shown`, 7x to 8x.** Whether a finding is shown is its severity's rank against the one asked
  for. The rank was found by respelling all six severities in camelCase, a `gsub` each, for every
  finding, twice. It is a table made when the module loads.
- **A dump as YAML, 2.4x on real geometry.** Two things. A list was spelled out
  whole to learn whether it fit on a line, then spelled again to be written, and a list of
  numbers goes on one line whatever its width: numbers are no longer spelled to be measured
  (`b7de8f8`, 1.7x by itself). And a float's shortest digits were matched out of each trial
  spelling with a pattern and two substitutions, from a format string built for each trial: the
  digits and exponent are read off their fixed places in the text, in seventeen formats made
  once (`466219f`, 1.4x more). What is left is the trial spellings themselves, up to nine
  `string.format` calls a float; the search for the fewest digits is the same search. The cold
  dump is the same 250 ms saved.
- **`isNifPath`, 4.4x.** It lowercased the whole path and cut two endings off the copy to compare
  them: three strings a call. It reads the last four bytes.
- **Listing a load order's models (`addBase`), 1.9x.** `isNifPath` is 1.34x of that. The rest
  (1.41x more) is the sort: the targets were sorted through a comparator that read each one's
  path, and now the paths are sorted as strings and the targets made in that order. A layer whose
  source is named no longer looks each file up to ask it.
- **`texturePath`, 2.3x.** The file name was matched by `([^/]*)$`, which Luau tries from every
  position in turn; it is what follows `bytes.rfind` of the separator (1.86x). The extension and
  the directory are found by their bytes too (1.15x more), and the rest is `normalize`.
- **`normalize`, 1.6x.** One `bytes.translate` call folds case and `\`. The first attempt asked
  the same call to collapse and trim the separators as well (`3258729`), and measured 0.77x:
  slower than the `string.lower` and two `gsub`s it replaced, because the call reads its options
  table every time. `df93927` leaves the options out and mends separators in Luau only when a path
  has any to mend, which is what the row shows.
- **A dump's records, 1.13x on real geometry.** A view's vectors are taken apart in the loop that
  walks them, without a call of `plain` for each.

What didn't move: the check, info, and the fixes are `@nif`'s time and `@vfs`'s, and every
document but a dump's YAML is written by `@jess/data/value`'s encoder (in a JSON dump its float
spelling is where the profiler counts most). The command line run once is mostly loading what it
requires: `help` pays 220 ms to print a page, because the command line requires every module,
`@nif` among them, before it reads an argument.

Tried against head, three rounds each, and not kept, because none reached 5 percent: handing
`numberText` the kind its caller had already worked out (YAML dump); a loop of its own for a
record's lists with numbers passed straight through (JSON, TOML, and YAML dump); remembering each
code's camelCase spelling (check, info); one VFS lookup for a texture that is found where there
are two (check); and the view loop above as a comprehension (dump).

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-15 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 1.46 and 1.44 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@nif-assets`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@nif-assets` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.197 s | 0.189 s |
| Final | 0.201 s | 0.187 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| normalize 256 written paths | 0.08701 | **1.375×** | 0.08209 | 0.943× |
| isNifPath over 4,096 keys | 0.1842 | **2.169×** | 0.1717 | 0.932× |
| texturePath for 256 written paths | 0.5279 | **1.503×** | 0.4960 | 0.940× |
| new + addBase over 4,096 keys | 1.579 | **1.390×** | 1.516 | 0.960× |
| new + addVfsTarget for 64 models | 0.1406 | **1.177×** | 0.1381 | 0.982× |
| check 67 models in a data folder | 6.029 | **1.056×** | 6.011 | 0.997× |
| checkBytes random_objects | 0.1222 | 1.048× | 0.1238 | 1.014× |
| shown: 2,680 files down to collision | 0.8005 | **1.371×** | 0.7800 | 0.974× |
| shown: 2,680 files, every file and finding | 1.200 | **1.197×** | 1.187 | 0.988× |
| infoBytes all_types | 0.01428 | **1.129×** | 0.01493 | 1.046× |
| infoBytes random_objects | 0.1836 | 1.043× | 0.1912 | 1.041× |
| info for 67 models in a data folder | 7.590 | **1.087×** | 7.899 | 1.041× |
| dump all_types | 0.5387 | **1.311×** | 0.5609 | 1.041× |
| dump random_objects | 2.500 | **1.509×** | 2.441 | 0.976× |
| dump random_objects, listed | 0.1321 | **1.057×** | 0.1342 | 1.016× |
| dump all_types, shapes named tri | 0.1440 | 1.021× | 0.1467 | 1.019× |
| dump a Skyrim node | 0.03460 | 0.998× | 0.03564 | 1.030× |
| fix 67 models, dry run | 4.089 | 1.010× | 4.301 | **1.052×** |
| parse 8 argument lists | 0.01938 | **1.479×** | 0.02607 | **1.345×** |
| render check of 67 models as yaml | 21.71 | 1.033× | 21.45 | 0.988× |
| render check of 67 models as json | 2.486 | 1.002× | 2.572 | 1.034× |
| render check of 67 models as toml | 3.920 | 0.752× | 4.035 | 1.029× |
| render info of 67 models as yaml | 32.68 | **1.059×** | 34.36 | **1.051×** |
| render info of 67 models as json | 4.436 | 0.871× | 4.381 | 0.988× |
| render info of 67 models as toml | 6.750 | 1.017× | 6.497 | 0.963× |
| render fix of 67 models as yaml | 2.831 | 1.014× | 2.960 | 1.046× |
| render fix of 67 models as json | 0.3650 | 0.998× | 0.3784 | 1.037× |
| render fix of 67 models as toml | 0.5985 | 0.910× | 0.6189 | 1.034× |
| render dump of all_types as yaml | 4.880 | **1.193×** | 5.248 | **1.075×** |
| render dump of all_types as json | 3.368 | **1.079×** | 3.501 | 1.040× |
| render dump of all_types as toml | 4.372 | **1.158×** | 4.425 | 1.012× |
| render dump of random_objects as yaml | 215.1 | **1.363×** | 206.3 | 0.959× |
| render dump of random_objects as json | 90.02 | 1.047× | 88.91 | 0.988× |
| render dump of random_objects as toml | 98.27 | **1.057×** | 99.76 | 1.015× |
| check command: sources, check, shown, YAML | 31.45 | **1.052×** | 31.48 | 1.001× |

What carries the directive (every module and function here is one a row spends its time in,
unmarked):

- Whole: `listing`, `plain`.
- `init`, by function: a closure at line 62, `normalize`, `isNifPath`, `fileName`,
  `changeExtension`, `findDirectory`, `resourcePath`, `texturePath`, `extendTargets`, `get`,
  `sourceName`, `sourceOf`, `addVfsTarget`, `keysOf`, `fileReport`, `shown`, `dump`.
- `render`, by function: `snake`, a closure at line 34, `list`, `plainValue`, a closure at line 380.
- Unmarked: `cli`, `commands`, `main`, `usage`.

`cli` and `main` parse a command line once a run and are never marked, so `parse 8 argument
lists` (1.35x, of a 19 µs call) is slower than all marked by rule. The three other rows above 5%
(a dry-run fix of 67 models, 1.052x; rendering their info as YAML, 1.051x; rendering a dump of
`all_types` as YAML, 1.075x) are inside this protocol's noise: two all-marked copies of
dream-archive, measured the same way, put 10 of 109 rows more than 5% apart, the 95th
percentile at 1.074x.
