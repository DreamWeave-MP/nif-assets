--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
`check`, `info`, and `fix` over many NIFs at once, with each NIF's textures looked up the way
OpenMW finds them: a port of jess-assets' NIF reports. NIFs come from sources: files, data
folders, and archives given as inputs, and a load order's VFS (an `@openmw` Context's `vfs()`)
underneath them, where textures are looked up too. A file inside a `meshes` folder brings that
folder's data folder along, so its textures resolve against its own mod. `dump` and `edit` read
one of those NIFs: its records as plain data, and the model to change it through.

The load order is taken as its `@vfs` VFS, not as the Context that made it: the VFS is all that
is read of one, so this depends on `@nif` and `@vfs` alone, and a caller without an openmw.cfg
builds a VFS over its folders itself.

Texture paths follow OpenMW's `correctTexturePath` (`components/misc/resourcehelpers.cpp`).
Reports are shaped as jess's are: camelCase fields, and codes in camelCase. `@nif/check` spells
its severities and codes in snake_case, as jess-nif did; they become camelCase here, where
jess-assets' reports spelled them for Luau.
]]

local Bytes = require '@dream/bytes'
local Check = require '@nif/check'
local Fix = require '@nif/fix'
local Header = require '@nif/header'
local Info = require '@nif/info'
local Nif = require '@nif'
local Plain = require '@self/plain'
local Reader = require '@nif/gamebryo'
local Vfs = require '@vfs'

--- Each severity's rank, most severe first, by the name `@nif/check` gives it. This mirrors the
--- ranks private to `@nif`'s check (`src/internal/check/types.luau`), which nothing exports: they
--- are an order, not an object anything shares, and here they order a file's findings once its
--- texture findings have joined the check's.
local Ranks: { [string]: number } = table.freeze {
  wont_load = 1,
  broken = 2,
  missing_asset = 3,
  collision = 4,
  performance = 5,
  info = 6,
}

--- A NIF to read: its VFS path, the data folder, archive, or file it came from, and the layer
--- it's read from (an input's index, 0 for the load order, -1 for a lone file).
export type Target = { path: string, source: string, layer: number }

export type Sources = {
  inputs: { { name: string, vfs: Vfs.VFS } },
  base: Vfs.VFS?,
  targets: { Target },
  targeted: { [string]: boolean },
}

--- Where a texture path led: the path OpenMW loads, whether it exists, and every path tried.
export type Resolved = { path: string, found: boolean, tried: { string } }

--- A code as jess spells codes in Luau: `missing_texture` is `missingTexture`.
local function camel(code: string): string
  return (
    string.gsub(code, '_(%l)', function(letter: string): string return string.upper(letter) end)
  )
end

--- Each severity's rank by the name a report gives it: `wontLoad` is 1.
local ReportRanks: { [string]: number } = {}
for severity, rank in Ranks do
  ReportRanks[camel(severity)] = rank
end

table.freeze(ReportRanks)

--- ASCII capitals and `\`, and what a VFS path spells them as.
local Folded, Folds = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ\\', 'abcdefghijklmnopqrstuvwxyz/'

local Separators = table.freeze { collapse = '/', trimStart = '/' }

--- OpenMW's VFS spelling: `\` becomes `/`, ASCII letters are lowercased, repeated separators
--- collapse, and a leading separator is dropped. A path already spelled so is returned as it is.
local function normalize(path: string): string
  return Bytes.translate(path, Folded, Folds, Separators)
end

--- Whether a VFS path is a NIF model or KF animation.
local function isNifPath(path: string): boolean
  local lower = string.lower(path)
  return string.sub(lower, -4) == '.nif' or string.sub(lower, -3) == '.kf'
end

local function isArchive(path: string): boolean
  local extension = string.match(string.lower(path), '%.(%w+)$')
  return extension == 'bsa' or extension == 'ba2' or extension == 'zip' or extension == '7z'
end

--- What follows the last separator: the whole path without one, nothing after a trailing one.
local function fileName(path: string): string
  local slash = Bytes.rfind(path, '/')
  return if slash then string.sub(path, slash + 2) else path
end

--- Replaces the extension of the last component, if it has one (`Normalized::changeExtension`).
local function changeExtension(path: string, extension: string): string?
  local stem = string.match(path, '^(.*)%.[^./]*$')
  if not stem then return nil end

  return `{stem}.{extension}`
end

--- Where `directory` starts as a whole component of `path`, 1-based. Like OpenMW, the search
--- gives up when a match runs to the end of the path.
local function findDirectory(path: string, directory: string): number?
  local offset = 1
  while offset <= #path do
    local position = string.find(path, directory, offset, true)
    if not position then return nil end

    local stop = position + #directory
    if stop > #path then return nil end

    if
      (position == 1 or string.sub(path, position - 1, position - 1) == '/')
      and string.sub(path, stop, stop) == '/'
    then
      return position
    end

    offset = stop
  end

  return nil
end

--- `correctResourcePath`: anything before the first of `directories` found in the path is
--- stripped (or the first one is prefixed), `extension` is preferred, and then the original
--- extension and the file name directly under the first directory are tried.
local function resourcePath(
  directories: { string },
  path: string,
  extension: string?,
  exists: (string) -> boolean
): Resolved
  path = normalize(path)
  local top = directories[1] or ''
  local found: string? = nil
  for _, directory in directories do
    local start = findDirectory(path, directory)
    if start then
      found = string.sub(path, start)
      break
    end
  end

  local corrected: string = found or `{top}/{path}`
  local changed = if extension then changeExtension(corrected, extension) else nil
  local preferred: string = changed or corrected
  local candidates: { string } = { preferred }
  if changed then table.insert(candidates, corrected) end

  table.insert(candidates, `{top}/{fileName(preferred)}`)
  if changed then table.insert(candidates, `{top}/{fileName(corrected)}`) end

  local tried: { string } = {}
  for _, candidate in candidates do
    if table.find(tried, candidate) then continue end

    local found = exists(candidate)
    table.insert(tried, candidate)
    if found then return { path = candidate, found = true, tried = tried } end
  end

  return { path = preferred, found = false, tried = tried }
end

--- `correctTexturePath`, for NIF textures and texture sets: under `textures` or `bookart`,
--- preferring `.dds`.
local function texturePath(path: string, exists: (string) -> boolean): Resolved
  return resourcePath({ 'textures', 'bookart' }, path, 'dds', exists)
end

--- A path's data folder and the path under it, when it's inside a `meshes` folder: the folder
--- above the last `meshes`, and the normalized path from `meshes` on.
local function dataRoot(path: string): (string?, string)
  local parts = string.split((string.gsub(path, '\\', '/')), '/')
  local position
  for index = #parts, 1, -1 do
    if string.lower(parts[index]) == 'meshes' then
      position = index
      break
    end
  end

  if not position then return nil, '' end

  local root = table.concat(parts, '/', 1, position - 1)
  if root == '' then root = if string.sub(path, 1, 1) == '/' then '/' else '.' end

  return root, normalize(table.concat(parts, '/', position))
end

--- Sources over `base`, the load order's VFS when there is one, with nothing to read yet: for a
--- caller that names the models itself, with `addVfsTarget`, rather than reading every one.
local function newSources(base: Vfs.VFS?): Sources
  return { inputs = {}, base = base, targets = {}, targeted = {} }
end

local function extendTargets(sources: Sources, targets: { Target })
  for _, target in targets do
    sources.targeted[target.path] = true
    table.insert(sources.targets, target)
  end
end

local function pushDirectory(sources: Sources, root: string)
  local last = sources.inputs[#sources.inputs]
  if last and last.name == root then return end

  local vfs = Vfs.VFS.new()
  vfs:pushDirectory(root)
  table.insert(sources.inputs, { name = root, vfs = vfs })
end

--- The winning file for a VFS path: the newest input first, then the load order.
local function get(sources: Sources, path: string): Vfs.VfsFile?
  for index = #sources.inputs, 1, -1 do
    local file = sources.inputs[index].vfs:getFile(path)
    if file then return file end
  end

  return if sources.base then sources.base:getFile(path) else nil
end

local function sourceName(file: Vfs.VfsFile): string
  return file:parentArchivePath() or file:path()
end

--- The data folder or archive a VFS path comes from.
local function sourceOf(sources: Sources, path: string): string?
  local file = get(sources, path)
  return if file then sourceName(file) else nil
end

--- Adds a data folder or archive to look textures up in, without reading the NIFs in it.
local function addData(sources: Sources, root: string)
  if not jess.fs.exists(root) then error(`'{root}' doesn't exist`, 0) end

  for _, input in sources.inputs do
    if input.name == root then return end
  end

  if jess.fs.isDir(root) then
    pushDirectory(sources, root)
    return
  end

  local vfs = Vfs.VFS.new()
  if not isArchive(root) or not vfs:pushArchive(root) then
    error(`'{root}' isn't a directory, NIF, KF, or archive`, 0)
  end

  table.insert(sources.inputs, { name = root, vfs = vfs })
end

--- Adds a NIF path the inputs or the load order hold as a target; whether one does.
local function addVfsTarget(sources: Sources, path: string): boolean
  path = normalize(path)
  if sources.targeted[path] then return true end

  local layer
  for index = #sources.inputs, 1, -1 do
    if sources.inputs[index].vfs:getFile(path) then
      layer = index
      break
    end
  end

  if not layer and sources.base and sources.base:getFile(path) then layer = 0 end

  if not layer then return false end

  extendTargets(sources, { { path = path, source = sourceOf(sources, path) or '', layer = layer } })
  return true
end

--- Every key of `vfs` that `wanted` takes and starts with `prefix`, as targets of `layer`.
local function keysOf(
  vfs: Vfs.VFS,
  prefix: string,
  wanted: (string) -> boolean,
  layer: number,
  source: string?
): { Target }
  local found: { Target } = {}
  for _, path in vfs:keys():toTable() do
    if string.sub(path, 1, #prefix) ~= prefix or not wanted(path) then continue end

    local file = vfs:getFile(path) :: Vfs.VfsFile
    table.insert(found, { path = path, source = source or sourceName(file), layer = layer })
  end

  table.sort(
    found,
    function(left: Target, right: Target): boolean return left.path < right.path end
  )
  return found
end

--- Adds an input: a NIF file, a data folder, or an archive, or a VFS path the sources hold.
local function add(sources: Sources, path: string, wanted: (string) -> boolean)
  if not jess.fs.exists(path) then
    local vfsPath = normalize(path)
    if wanted(vfsPath) and addVfsTarget(sources, vfsPath) then return end

    error(`'{path}' doesn't exist`, 0)
  end

  local root, prefix = dataRoot(path)
  if jess.fs.isFile(path) and not isArchive(path) then
    local name = jess.fs.fileName(path) or ''
    if not wanted(normalize(name)) then
      error(`'{path}' isn't a directory, NIF, KF, or archive`, 0)
    end

    if root then
      pushDirectory(sources, root)
      extendTargets(sources, { { path = prefix, source = path, layer = #sources.inputs } })
    else
      extendTargets(sources, { { path = normalize(name), source = path, layer = -1 } })
    end

    return
  end

  local layerRoot
  if jess.fs.isDir(path) then
    layerRoot = root or path
    pushDirectory(sources, layerRoot)
  else
    local vfs = Vfs.VFS.new()
    if not vfs:pushArchive(path) then
      error(`'{path}' isn't a directory, NIF, KF, or archive`, 0)
    end

    table.insert(sources.inputs, { name = path, vfs = vfs })
    layerRoot, prefix = path, ''
  end

  local index = #sources.inputs
  extendTargets(sources, keysOf(sources.inputs[index].vfs, prefix, wanted, index, layerRoot))
end

--- Every NIF the load order holds, as targets.
local function addBase(sources: Sources, wanted: (string) -> boolean)
  local base = sources.base
  if not base then return end

  extendTargets(sources, keysOf(base, '', wanted, 0, nil))
end

--- Sources over `base`, the load order's VFS when there is one: the `data` folders and archives
--- to look textures up in, then `inputs`, or every NIF in the load order without any.
local function sources(base: Vfs.VFS?, data: { string }?, inputs: { string }?): Sources
  local made = newSources(base)
  for _, folder in data or {} do
    addData(made, folder)
  end

  if not inputs or #inputs == 0 then addBase(made, isNifPath) end

  for _, input in inputs or {} do
    add(made, input, isNifPath)
  end

  return made
end

local function hasLookups(made: Sources): boolean return made.base ~= nil or #made.inputs > 0 end

--- A target's bytes.
local function readTarget(made: Sources, target: Target): buffer
  if target.layer == -1 then
    local text = jess.fs.read(target.source)
    if not text then error(`{target.path}: file not found`, 0) end

    return buffer.fromstring(text)
  end

  local vfs = if target.layer == 0 then made.base else made.inputs[target.layer].vfs
  local file = vfs and vfs:getFile(target.path)
  if not file then error(target.path, 0) end

  return file:readAllBuffer()
end

--- The loose file a target is, for writing back over; nil inside an archive.
local function targetFile(made: Sources, target: Target): string?
  if target.layer == -1 then return target.source end

  local vfs = if target.layer == 0 then made.base else made.inputs[target.layer].vfs
  local file = vfs and vfs:getFile(target.path)
  if not file or not file:isLoose() then return nil end

  return file:path()
end

export type FindingReport = { severity: string, code: string, message: string, record: number? }

export type TextureReport = { path: string, resolved: string?, source: string? }

export type FileReport = {
  path: string,
  source: string,
  version: string?,
  game: string?,
  deeplyChecked: boolean,
  worst: string?,
  findings: { FindingReport },
  textures: { TextureReport },
  stats: Check.Stats?,
}

--- One NIF's check, as a report: findings, and textures resolved against `made` when `lookups`.
local function fileReport(
  made: Sources,
  path: string,
  source: string,
  report: Check.Report,
  lookups: boolean
): FileReport
  type Ranked = { finding: FindingReport, rank: number, position: number }
  local ranked: { Ranked } = {}
  local function push(severity: string, code: string, message: string, record: number?)
    table.insert(ranked, {
      finding = {
        severity = camel(severity),
        code = camel(code),
        message = message,
        record = record,
      },
      rank = Ranks[severity] or math.huge,
      position = #ranked + 1,
    })
  end

  for _, finding in report.findings do
    push(finding.severity, finding.code, finding.message, finding.record)
  end

  local textures: { TextureReport } = {}
  for _, texture in report.textures do
    if not lookups then
      table.insert(textures, { path = texture })
      continue
    end

    local resolved = texturePath(
      texture,
      function(candidate: string): boolean return get(made, candidate) ~= nil end
    )
    if resolved.found then
      if string.sub(resolved.path, -4) ~= '.dds' then
        push(
          'performance',
          'uncompressed_texture',
          `"{resolved.path}" isn't a DDS file, so it loads uncompressed and has its mipmaps built at load time`
        )
      end
    else
      push(
        'missing_asset',
        'missing_texture',
        `texture "{texture}" not found (tried {table.concat(resolved.tried, ', ')})`
      )
    end

    table.insert(textures, {
      path = texture,
      source = if resolved.found then sourceOf(made, resolved.path) else nil,
      resolved = if resolved.found then resolved.path else nil,
    })
  end

  -- Most severe first, then by record, a finding about no record first; a stable sort.
  table.sort(ranked, function(left: Ranked, right: Ranked): boolean
    if left.rank ~= right.rank then return left.rank < right.rank end

    local leftRecord, rightRecord = left.finding.record or -1, right.finding.record or -1
    if leftRecord ~= rightRecord then return leftRecord < rightRecord end

    return left.position < right.position
  end)

  local findings = table.create(#ranked) :: { FindingReport }
  for position, entry in ranked do
    findings[position] = entry.finding
  end

  local header = report.header
  return {
    path = path,
    source = source,
    version = if header then Header.versionString(header.version) else nil,
    game = if header then Header.game(header) else nil,
    deeplyChecked = report.deep,
    worst = if findings[1] then findings[1].severity else nil,
    findings = findings,
    textures = textures,
    stats = report.stats,
  }
end

--- Checks one NIF's bytes, resolving its textures against `made`.
local function checkBytes(
  made: Sources,
  path: string,
  source: string,
  bytes: buffer
): FileReport
  return fileReport(made, path, source, Check.check(path, bytes), hasLookups(made))
end

local function checkTarget(made: Sources, target: Target, lookups: boolean): FileReport
  -- A target that has gone since the sources were made has no file to read, and `@vfs` throws for
  -- a file it can't read or an archive entry it can't unpack. Either way the NIF is reported as
  -- one OpenMW won't load, and the rest are still checked.
  local ok, bytes = pcall(readTarget, made, target)
  if ok then
    return fileReport(made, target.path, target.source, Check.check(target.path, bytes), lookups)
  end

  local report: Check.Report = {
    deep = false,
    findings = {
      { severity = 'wont_load', code = 'unreadable_file', message = `failed to read: {bytes}` },
    },
    textures = {},
  }
  return fileReport(made, target.path, target.source, report, false)
end

export type CheckReport = {
  summary: {
    texturesChecked: boolean,
    loadOrderChecked: boolean,
    files: number,
    deeplyChecked: number,
    wontLoad: number,
    byWorstSeverity: { [string]: number },
    byCode: { [string]: number },
  },
  files: { FileReport },
}

--- Checks every target in `made`.
local function checkSources(made: Sources): CheckReport
  local lookups = hasLookups(made)
  local files = {}
  for _, target in made.targets do
    table.insert(files, checkTarget(made, target, lookups))
  end

  local summary = {
    texturesChecked = lookups,
    loadOrderChecked = made.base ~= nil,
    files = #files,
    deeplyChecked = 0,
    wontLoad = 0,
    byWorstSeverity = {},
    byCode = {},
  }

  for _, file in files do
    if file.deeplyChecked then
      summary.deeplyChecked += 1
    end

    local worst = file.worst
    if worst then
      summary.byWorstSeverity[worst] = (summary.byWorstSeverity[worst] or 0) + 1
      if worst == 'wontLoad' then
        summary.wontLoad += 1
      end
    end

    local codes: { [string]: boolean } = {}
    for _, finding in file.findings do
      codes[finding.code] = true
    end

    for code in codes do
      summary.byCode[code] = (summary.byCode[code] or 0) + 1
    end
  end

  return { summary = summary, files = files }
end

--- Whether a finding of `severity` (camelCase) is at least as severe as `show`; a severity jess
--- doesn't know is always shown.
local function shows(severity: string, show: string): boolean
  return (ReportRanks[severity] or 0) <= (ReportRanks[show] or 0)
end

--- The report down to `show`: findings less severe are left out, and so are files left without
--- any, unless `everyFile`. The summary still counts everything.
local function shown(report: CheckReport, show: string, everyFile: boolean): CheckReport
  local files = {}
  for _, file in report.files do
    local kept = {}
    for _, finding in file.findings do
      if shows(finding.severity, show) then table.insert(kept, finding) end
    end

    if not everyFile and #kept == 0 then continue end

    local copy = table.clone(file)
    copy.findings = kept
    table.insert(files, copy)
  end

  return { summary = report.summary, files = files }
end

export type InfoReport = {
  path: string,
  source: string,
  version: string?,
  game: string?,
  userVersion: number?,
  bethVersion: number?,
  author: string?,
  recordCount: number?,
  recordTypes: { [string]: number },
  error: string?,
  collision: { source: string, node: number?, hidesMarkers: boolean, bsxFlags: number? }?,
  stats: Check.Stats?,
  textures: { TextureReport },
  tree: { Info.TreeNode },
}

--- A NIF's header, scene graph, collision setup, statistics, and textures, resolving its
--- textures against `made`.
local function infoBytes(made: Sources, path: string, source: string, bytes: buffer): InfoReport
  local report = Check.check(path, bytes)
  local file = fileReport(made, path, source, report, hasLookups(made))
  local header = report.header
  local morrowind = header ~= nil and header.version == Header.versions.morrowind
  local counts: { [string]: number }, tree = {}, {}
  local read = false
  if report.deep and morrowind then
    -- The model throws for a record it can't read. The check read this file with the
    -- multi-version reader, which takes some records the model refuses; the header's type table
    -- then stands in for the counts.
    local ok, nif = pcall(Nif.open, bytes)
    if ok then
      counts, tree, read = Info.recordTypeCounts(nif), Info.sceneTree(nif), true
    end
  elseif report.deep then
    -- The multi-version reader throws for a file OpenMW refuses. The check has just read this
    -- one with it, so a throw here would be the reader disagreeing with itself; the header's
    -- type table stands in then too.
    local ok, opened = pcall(Reader.open, bytes)
    if ok then
      counts, tree, read = Info.fileTypeCounts(opened), Info.fileSceneTree(opened), true
    end
  end

  if not read and header then
    for index = 0, #header.recordTypeIndices - 1 do
      local name = Header.recordType(header, index)
      if name then counts[name] = (counts[name] or 0) + 1 end
    end
  end

  local errorMessage
  for _, finding in report.findings do
    if finding.severity == 'wont_load' then
      errorMessage = finding.message
      break
    end
  end

  local collision = report.collision
  return {
    path = path,
    source = source,
    version = file.version,
    game = file.game,
    userVersion = if header then header.userVersion else nil,
    bethVersion = if header then header.bethVersion else nil,
    author = if header then header.author else nil,
    recordCount = if header then header.recordCount else nil,
    recordTypes = counts,
    error = errorMessage,
    collision = if collision
      then {
        source = camel(collision.source),
        node = collision.node,
        hidesMarkers = collision.hidesMarkers,
        bsxFlags = collision.bsxFlags,
      }
      else nil,
    stats = file.stats,
    textures = file.textures,
    tree = tree,
  }
end

--- `infoBytes` for every target in `made`.
local function infoSources(made: Sources): { InfoReport }
  local reports = {}
  for _, target in made.targets do
    -- As in `checkTarget`: a target that has gone, or one `@vfs` can't read, throws.
    local ok, bytes = pcall(readTarget, made, target)
    if ok then
      table.insert(reports, infoBytes(made, target.path, target.source, bytes))
    else
      table.insert(reports, {
        path = target.path,
        source = target.source,
        recordTypes = {},
        error = `failed to read: {bytes}`,
        textures = {},
        tree = {},
      })
    end
  end

  return reports
end

--- A target's bytes, for a caller with nothing to report but the failure.
local function targetBytes(made: Sources, target: Target): buffer
  -- As in `checkTarget`: a target that has gone, or one `@vfs` can't read, throws.
  local ok, bytes = pcall(readTarget, made, target)
  if not ok then error(`failed to read {target.path}: {bytes}`, 0) end

  return bytes
end

--- A target's header, or OpenMW's reason for refusing it, after the file's name.
local function targetHeader(target: Target, bytes: buffer): Header.Header
  -- The header reader throws OpenMW's message for a header it refuses.
  local parsed, header = pcall(Header.parse, bytes)
  if not parsed then error(`{target.path}: {header}`, 0) end

  return header
end

--- A Morrowind NIF read to edit: the model, the loose file it came from (nil inside an archive),
--- and its VFS path, or the name it was given as.
export type Editable = { nif: Nif.Nif, file: string?, path: string }

--- Reads a target to edit. Only Morrowind's NIFs fit the editable model, so any other game's is
--- refused, with the game and version it is.
local function edit(made: Sources, target: Target): Editable
  local bytes = targetBytes(made, target)
  local header = targetHeader(target, bytes)
  if header.version ~= Header.versions.morrowind then
    error(
      `{target.path} is a {Header.game(header)} {Header.versionString(header.version)} NIF; jess only edits Morrowind (4.0.0.2) NIFs so far`,
      0
    )
  end

  -- The model throws for a record it can't read.
  local opened, nif = pcall(Nif.open, bytes)
  if not opened then error(`{target.path}: {nif}`, 0) end

  return { nif = nif, file = targetFile(made, target), path = target.path }
end

export type DumpOptions = {
  --- Only records of these types, ignoring case; every type without any.
  types: { string }?,
  --- Only the records at these 0-based indices; every one without any.
  indices: { number }?,
  --- Only records whose name matches this case-insensitive regex.
  name: string?,
  --- Each record's `index`, `type`, and `name` (when it has one) only.
  list: boolean?,
}

--- A NIF's records: where it came from, the root links as the file has them (-1 for none), and
--- each record `options` picks as plain data, its fields by name with its 0-based `index` and
--- `type`. A link is the index of the record it points to.
export type Dump = {
  path: string,
  source: string,
  roots: { number },
  records: { { [string]: unknown } },
}

--- The records of another game's NIF that `options` picks, read as OpenMW reads them.
local function gamebryoRecords(
  file: Reader.File,
  options: DumpOptions,
  pattern: Regex?
): { { [string]: unknown } }
  local types: { [string]: boolean }? = nil
  if options.types and #options.types > 0 then
    local wanted: { [string]: boolean } = {}
    for _, name in options.types do
      wanted[string.lower(name)] = true
    end

    types = wanted
  end

  local indices = if options.indices and #options.indices > 0 then options.indices else nil
  local records: { { [string]: unknown } } = {}
  for slot, record in file.records :: { { [string]: unknown } } do
    local index, typeName = slot - 1, file.names[slot]
    if types and not types[string.lower(typeName)] then continue end

    if indices and not table.find(indices, index) then continue end

    local name = record.name
    if pattern and (type(name) ~= 'string' or not pattern:isMatch(name)) then continue end

    if options.list then
      table.insert(records, {
        index = index,
        type = typeName,
        name = if type(name) == 'string' and name ~= '' then name else nil,
      })
      continue
    end

    -- A class with a `type` field of its own keeps it, as jess-nif's dump did.
    local entry = Plain.plain(record) :: { [string]: unknown }
    entry.index = index
    if entry.type == nil then entry.type = typeName end

    table.insert(records, entry)
  end

  return records
end

--- A target's records, read by the reader for its version: the editable model for Morrowind's,
--- `@nif/gamebryo` for every other version OpenMW reads.
local function dump(made: Sources, target: Target, options: DumpOptions?): Dump
  local settings: DumpOptions = options or {}
  local pattern: Regex? = nil
  if settings.name then
    -- `jess.regex.new` throws for a pattern Rust's regex crate rejects, with its reason.
    local compiled, regex = pcall(jess.regex.new, settings.name, { caseInsensitive = true })
    if not compiled then error(`invalid name regex: {regex}`, 0) end

    pattern = regex
  end

  local bytes = targetBytes(made, target)
  local header = targetHeader(target, bytes)
  if header.version ~= Header.versions.morrowind then
    -- The multi-version reader throws `{ message, record }` for a file OpenMW refuses.
    local read, file = pcall(Reader.open, bytes)
    if not read then
      local problem = file :: unknown
      if type(problem) ~= 'table' then error(`{target.path}: {problem}`, 0) end

      local refusal = problem :: { message: string, record: number? }
      local recordType = if refusal.record then Header.recordType(header, refusal.record) else nil
      local prefix = if recordType then `{recordType}: ` else ''
      error(`{target.path}: {prefix}{refusal.message}`, 0)
    end

    return {
      path = target.path,
      source = target.source,
      roots = table.clone(file.roots),
      records = gamebryoRecords(file, settings, pattern),
    }
  end

  -- The model throws for a record it can't read.
  local opened, nif = pcall(Nif.open, bytes)
  if not opened then error(`{target.path}: {nif}`, 0) end

  -- An empty list of types or indices picks every record here, and none in the model's `dump`.
  local dumped = nif:dump {
    type = if settings.types and #settings.types > 0 then settings.types else nil,
    index = if settings.indices and #settings.indices > 0 then settings.indices else nil,
    name = settings.name,
    list = settings.list,
  }

  local records = table.create(#dumped.records) :: { { [string]: unknown } }
  for position, record in dumped.records do
    records[position] = Plain.plain(record) :: { [string]: unknown }
  end

  return { path = target.path, source = target.source, roots = dumped.roots, records = records }
end

export type FixOptions = {
  --- The fixes to make (`rcn`, `ncc`, `markers`, `skinWeights`, `unreachable`); every one by
  --- default.
  only: { Fix.Kind }?,
  --- Report what would change without writing anything.
  dryRun: boolean?,
  --- A data folder to write fixed files into, at their VFS paths, instead of over the originals.
  output: string?,
  --- Whether a file written over is backed up first (`.bak`); true by default.
  backup: boolean?,
}

export type FixedFile = {
  path: string,
  source: string,
  fixes: { { fix: string, message: string, record: number? } },
  written: { path: string, backup: string? }?,
  skipped: string?,
}

export type FixReport = {
  summary: {
    files: number,
    fixed: number,
    written: number,
    skipped: number,
    byFix: { [string]: number },
  },
  files: { FixedFile },
}

local function fixTarget(made: Sources, target: Target, options: FixOptions): FixedFile?
  local file: FixedFile = { path = target.path, source = target.source, fixes = {} }
  -- As in `checkTarget`: a target that has gone, or one `@vfs` can't read, throws.
  local ok, bytes = pcall(readTarget, made, target)
  if not ok then
    file.skipped = `failed to read {target.path}: {bytes}`
    return file
  end

  -- The header reader throws OpenMW's message for a header it refuses.
  local parsed, header = pcall(Header.parse, bytes)
  if not parsed then
    file.skipped = `{target.path}: {header}`
    return file
  end

  -- jess only edits Morrowind's NIFs, so there's nothing to fix in other games'.
  if (header :: Header.Header).version ~= Header.versions.morrowind then return nil end

  -- The model throws for a record it can't read, and a file that doesn't read can't be fixed.
  local opened, nif = pcall(Nif.open, bytes)
  if not opened then
    file.skipped = `{target.path}: {nif}`
    return file
  end

  local fixed = Fix.fix(nif, options.only)
  if #fixed == 0 then return nil end

  for _, entry in fixed do
    table.insert(file.fixes, { fix = entry.fix, message = entry.message, record = entry.record })
  end

  if options.dryRun then return file end

  local path
  if options.output then
    path = jess.fs.join(options.output, target.path)
  else
    path = targetFile(made, target)
    if not path then
      file.skipped = 'it\'s in an archive; use --output to write fixed files to a folder'
      return file
    end
  end

  local destination: string = path :: string
  -- `jess.fs.write` throws when the file, or its backup, can't be written. The file is reported
  -- as skipped with the reason, and the rest are still fixed.
  local wrote, written = pcall(
    function() return jess.fs.write(destination, nif:save(), { backup = options.backup ~= false }) end
  )
  if wrote then
    file.written = written
  else
    file.skipped = tostring(written)
  end

  return file
end

--- Fixes every target in `made`. Only files that need a fix are listed.
local function fixSources(made: Sources, options: FixOptions?): FixReport
  local settings: FixOptions = options or {}
  local files = {}
  for _, target in made.targets do
    local file = fixTarget(made, target, settings)
    if file then table.insert(files, file) end
  end

  local summary = { files = #made.targets, fixed = 0, written = 0, skipped = 0, byFix = {} }
  for _, file in files do
    if #file.fixes > 0 and not file.skipped then
      summary.fixed += 1
    end

    if file.written then
      summary.written += 1
    end

    if file.skipped then
      summary.skipped += 1
    end

    local kinds: { [string]: boolean } = {}
    for _, entry in file.fixes do
      kinds[entry.fix] = true
    end

    for kind in kinds do
      summary.byFix[kind] = (summary.byFix[kind] or 0) + 1
    end
  end

  return { summary = summary, files = files }
end

return table.freeze {
  normalize = normalize,
  isNifPath = isNifPath,
  texturePath = texturePath,
  resourcePath = resourcePath,
  new = newSources,
  sources = sources,
  addData = addData,
  add = add,
  addBase = addBase,
  addVfsTarget = addVfsTarget,
  readTarget = readTarget,
  targetFile = targetFile,
  sourceOf = sourceOf,
  checkBytes = checkBytes,
  check = checkSources,
  shown = shown,
  infoBytes = infoBytes,
  info = infoSources,
  edit = edit,
  dump = dump,
  fix = fixSources,
}
