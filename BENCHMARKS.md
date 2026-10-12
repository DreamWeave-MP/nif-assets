# nif-assets benchmarks

`bench/bench.luau` times the package through its public modules: the path rules (`normalize`,
`isNifPath`, `texturePath`), a load order's models listed as targets, the check with its texture
lookups, the report cut down to what is shown, info, dump, the dry run of the fixes, the argument
list read, and every document the command line prints, in each format. The models are the suite's
two files (`all_types.nif`, every record type once, 16 KB; `random_objects.nif`, eight shapes,
233 KB), a Skyrim node spelled by hand, and 64 small ones built in the bench with `@nif`, written
to a data folder in scratch beside a folder of 4,096 empty files to list. A warm workload is
warmed up, sized to a batch of about a tenth of a second, and reported as the median of seven
batches with a full collection between them. A `cold:` workload is the median of seven fresh
processes running `bench/cold.luau`, which is the command line run once, timed inside the script
from its first `require`: most of it is compiling the modules it loads. Every workload's answer
is compared with one pinned in the file: a count, or the checksum and length of the document.

```sh
jess run --capability filesystem.read --capability filesystem.write --capability process.spawn \
  --package jpk/nif-assets --package-path jpk jpk/nif-assets/bench/bench.luau \
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
