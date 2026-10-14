--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- What `nif-assets --help` and `nif-assets <command> --help` print: the summaries and argument
-- descriptions `jess nif` had, under this command's name.

local Top = [[
nif-assets: check, describe, dump, and fix NIF models and animations

  nif-assets [--format <yaml|json|toml>] <command> [options] <inputs>...
  nif-assets <command> --help
  nif-assets help [<command>]

Commands:
  check   Check NIFs the way OpenMW loads them: what won't load, what draws or collides wrong,
          missing textures, and performance smells. Exits 1 when anything won't load.
  info    Describe NIFs: header, record types, scene graph, collision setup, statistics, and
          textures with where OpenMW finds them.
  dump    Dump a NIF's records with every field. Links are record indices.
  fix     Repair what check finds that has one clear fix, backing up each file first. Exits 1
          when a file needing fixes couldn't be fixed.
  modify  Run a Luau script on a Morrowind NIF. Refused: a package can't load a script it is
          handed when it runs. @nif-assets/commands' modify takes the edit as a function.

An input is a NIF or KF file, a data folder (searched recursively), an archive (.bsa, .ba2), or a
VFS path like meshes/f/furn_de_bed_01.nif found in the --data folders and archives. Textures are
looked up in the inputs, then in the --data folders and archives, later ones winning. There is no
load order behind any of it: what isn't named isn't searched.

  --format <yaml|json|toml>  Output format: YAML (the default), compact one-line JSON, or TOML.
                             Goes before or after the command.

Exit status: 0 done, whatever was found; 1 check found a file that won't load, or fix left a file
that needed fixing unfixed; 8 the command line can't be used; 9 the run failed.]]

local Format = [[
      --format <FORMAT>  Output format: YAML (the default), compact one-line JSON, or TOML
                         [possible values: yaml, json, toml]
  -h, --help             Print help]]

local Statuses = 'Exit status: 0 done, whatever was found; %s8 the command line can\'t be used;\n'
  .. '9 the run failed.'

local Check = [[
Check NIFs the way OpenMW loads them: what won't load, what draws or collides wrong, missing
textures, and performance smells. Exits 1 when anything won't load.

Usage: nif-assets check [OPTIONS] <INPUTS>...

Arguments:
  <INPUTS>...  NIF/KF files, data folders, or archives to check. Textures resolve against them
               and the --data folders

Options:
      --show <SHOW>      The least severe findings to include; files without any are left out
                         [default: collision] [possible values: wont-load, broken,
                         missing-asset, collision, performance, info]
  -v, --verbose          Include every file and every finding, down to informational ones
      --data <PATH>      A data folder or archive to look textures up in, without checking its
                         NIFs. Can be repeated; later ones win, and the inputs win over all of
                         them
]] .. Format .. '\n\n' .. string.format(Statuses, '1 a file won\'t load; ')

local Info = [[
Describe NIFs: header, record types, scene graph, collision setup, statistics, and textures with
where OpenMW finds them.

Usage: nif-assets info [OPTIONS] <INPUTS>...

Arguments:
  <INPUTS>...  NIF/KF files, data folders, or archives to describe

Options:
      --no-tree          Leave out the scene graph
      --data <PATH>      A data folder or archive to look textures up in. Can be repeated
]] .. Format .. '\n\n' .. string.format(Statuses, '')

local Dump = [[
Dump a NIF's records with every field. Links are record indices.

Usage: nif-assets dump [OPTIONS] <INPUT>

Arguments:
  <INPUT>  The NIF or KF file, or its VFS path in a --data folder or archive, like
           meshes/f/furn_de_bed_01.nif

Options:
  -t, --type <TYPES>     Only records of this type, like NiTriShape. Can be repeated
      --index <INDEX>    Only the record at this index. Can be repeated
      --name <NAME>      Only records whose name matches this case-insensitive regex
      --list             Only list the matching records' index, type, and name
      --data <PATH>      A data folder or archive to find the input's VFS path in. Can be
                         repeated; later ones win
]] .. Format .. '\n\n' .. string.format(Statuses, '')

local Fix = [[
Repair what check finds that has one clear fix, backing up each file first. Exits 1 when a file
needing fixes couldn't be fixed.

Usage: nif-assets fix [OPTIONS] <INPUTS>...

Arguments:
  <INPUTS>...  NIF/KF files, data folders, or archives

Options:
      --only <ONLY>      Only these fixes. Without it, all of them

                         Possible values:
                         - rcn:          Add RCN string data when the root collision node is
                                         nested under a child
                         - ncc:          Uppercase ncc string data, which otherwise turns off
                                         camera collision too
                         - markers:      Add MRK string data when editor marker shapes would draw
                         - skin-weights: Drop skin weights for vertices the shape doesn't have
                         - unreachable:  Drop records nothing links to

      --dry-run          Report what would change without writing anything
      --no-backup        Don't back up files before writing over them (normally copied to .bak,
                         .bak1, ...)
      --output <DIR>     Write fixed files into this data folder at their VFS paths, instead of
                         over the originals. Needed for files in archives
      --data <PATH>      A data folder or archive to look textures up in, without fixing its
                         NIFs. Can be repeated; later ones win, and the inputs win over all of
                         them
]] .. Format .. '\n\n' .. string.format(
  Statuses,
  '1 a file needing fixes wasn\'t fixed; '
)

local Modify = [[
Run a Luau script on a Morrowind NIF: it gets (nif, path) as its arguments, and the NIF is
written, after a backup, if the script changed it.

Refused: nif-assets modify can't run. A package can't load and run a Luau script it is handed
when it runs, so there is nothing to give --script to. @nif-assets/commands' modify does the
rest of what this command did (the backup, --output, --dry-run), with the edit as a function:
a script of your own, run with jess run, requires it and passes the edit in.]]

return table.freeze {
  top = Top,
  commands = table.freeze {
    check = Check,
    info = Info,
    dump = Dump,
    fix = Fix,
    modify = Modify,
  } :: { [string]: string },
}
