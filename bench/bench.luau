--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
nif-assets, timed through its public modules: the path rules, a load order's models listed as
targets, the check with its texture lookups, the report cut down to what is shown, info, dump,
the dry run of the fixes, the argument list read, and every document the command line prints;
and the command line itself, run once.

  jess run --capability filesystem.read --capability filesystem.write \
    --capability process.spawn --package . --package-path .. \
    bench/bench.luau <scratch> [filter] [jess binary] [package path]

The models are the suite's two files (`all_types.nif`, every record type once, 16 KB;
`random_objects.nif`, eight shapes, 233 KB), a Skyrim node spelled by hand, and 64 small ones
built here with `@nif`: a shape whose texture is there as a DDS, one whose texture is only a TGA,
one whose texture is missing, and one with the defects the fixes repair. They are written to a
data folder under `<scratch>`, beside a second folder of 4,096 empty files to list.

One line per workload, `name<TAB>seconds per call`: the median of seven batches of about a tenth
of a second each, with a full collection between batches. Every workload's answer is weighed
before the first batch and after the last, outside the time, and compared with the one pinned
here, so a path that stops doing its work fails instead of posting a time.

Given the jess binary to start (and `process.spawn`), the cold workloads too: what one process
pays for one command from its first `require` on, when compiling the modules it needs is most of
the work. Each is the median of seven processes running `cold.luau`, which find the packages
this one depends on in the package path, the folder above this package without one.
]]

local assets = require '@nif-assets'
local bytes = require '@dream/bytes'
local cli = require '@nif-assets/cli'
local commands = require '@nif-assets/commands'
local fs = require '@dream/fs'
local nif = require '@nif'
local process = require '@dream/process'
local vfs = require '@vfs'

-- A build without the verified toolchain runs Luau slower than a release does, so a number from
-- one says nothing about what ships.
if not jess.bench.verified then
  error(
    'nif-assets bench: this jess was built without the verified toolchain: measure on a release',
    0
  )
end

local scratch: string?, filter: string?, binary: string?, packages: string? = ...
if not scratch then error('nif-assets bench: a scratch folder is required', 0) end

local only = if filter and filter ~= '' then filter else nil

--- Where this file is, from its chunk name: the suite's assets are beside its folder.
local function here(): string
  local source = debug.info(1, 's')
  local first = string.sub(source, 1, 1)
  local path = if first == '@' or first == '=' then string.sub(source, 2) else source

  return string.match(path, '^(.*)/[^/]*$') or '.'
end

local Here = here()
local PackagePath = packages or `{Here}/../..`

local function asset(name: string): string
  local path = `{Here}/../tests/assets/{name}`
  return jess.fs.read(path) or error(`nif-assets bench: can't read {path}`, 0)
end

local function median(samples: { number }): number
  table.sort(samples)
  return samples[(#samples + 1) // 2]
end

--- Times `body`. `weigh` makes a number of what a call returned, outside the time, and that
--- number must be `expected`.
local function workload<Answer>(
  name: string,
  expected: number,
  body: () -> Answer,
  weigh: (answer: Answer) -> number
)
  if only and not string.find(name, only, 1, true) then return end

  local function verify()
    local weight = weigh(body())
    if weight ~= expected then error(`{name}: answered {weight}, not {expected}`, 0) end
  end

  jess.bench.collect()
  verify()
  local start = os.clock()
  body()
  local single = math.max(os.clock() - start, 1e-7)
  local iterations = math.max(1, math.floor(0.1 / single))
  local samples = {}
  for batch = 1, 7 do
    jess.bench.collect()
    start = os.clock()
    for _ = 1, iterations do
      body()
    end

    samples[batch] = (os.clock() - start) / iterations
  end

  verify()
  print(`{name}\t{string.format('%.9f', median(samples))}`)
end

local function same(answer: number): number return answer end

local ScratchPattern = string.gsub(scratch, '%p', '%%%0')

--- A document's checksum and length as one whole number, with the scratch folder's own name,
--- which is the caller's choice, taken out of it.
local function textWeight(text: string): number
  local portable = string.gsub(text, ScratchPattern, '')
  return bytes.crc32(portable) * 2 ^ 20 + #portable % 2 ^ 20
end

--- How many values are under `value`, each number and string counted by what it is: in whole
--- numbers, so the order a table is walked in can't move the total.
local function deepWeight(value: unknown): number
  if type(value) == 'number' then
    local number = value :: number
    return if number ~= number then 3 else 1 + math.floor(math.abs(number) * 1000) % 7
  end

  if type(value) == 'string' then return 1 + #(value :: string) end

  if type(value) ~= 'table' then return 1 end

  local total = 1
  for _, entry in value :: { [unknown]: unknown } do
    total += deepWeight(entry)
  end

  return total
end

local Triangle = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } }

--- A triangle under a root node, drawn with `texture`.
local function textured(name: string, texture: string): buffer
  local file = nif.new()
  local root = file:insert { type = 'NiNode', name = name }
  file:shape {
    name = `Tri {name}`,
    vertices = Triangle,
    triangles = { { 0, 1, 2 } },
    texture = texture,
    parent = root,
  }
  file.roots = { root }

  return file:save()
end

--- A model with what the check finds and the fixes repair: a lowercase `NCc`, a collision node
--- OpenMW doesn't find, and an editor marker that draws, with a texture nothing provides.
local function defects(name: string, texture: string): buffer
  local file = nif.new()
  local root = file:insert { type = 'NiNode', name = name }
  local lowercase = file:insert { type = 'NiStringExtraData', value = 'NCc', bytesRemaining = 7 }
  local rootNode = file:record(root) :: { [string]: unknown }
  rootNode.extraData = lowercase

  local inner = file:insert { type = 'NiNode', name = 'Inner' }
  file:attach(root, inner)
  file:attach(inner, file:insert { type = 'RootCollisionNode', name = 'RootCollisionNode' })
  file:shape {
    name = 'Tri EditorMarker 0',
    vertices = Triangle,
    triangles = { { 0, 1, 2 } },
    texture = texture,
    parent = root,
  }
  file.roots = { root }

  return file:save()
end

local function u32(value: number): string return string.pack('<I4', value) end

local function i32(value: number): string return string.pack('<i4', value) end

local function f32(value: number): string return string.pack('<f', value) end

local function sized(text: string): string return u32(#text) .. text end

local function short(text: string): string return string.pack('<I1', #text) .. text end

local SkyrimNode = i32(0)
  .. u32(0)
  .. i32(-1)
  .. u32(14)
  .. f32(1)
  .. f32(2)
  .. f32(3)
  .. string.rep(f32(1) .. f32(0) .. f32(0) .. f32(0), 2)
  .. f32(1)
  .. f32(1)
  .. i32(-1)
  .. u32(0)
  .. u32(0)

--- A Skyrim file (20.2.0.7, user version 12, stream 83) holding one `NiNode` named
--- `Scene Root`, as the suite writes it: a model of another game, read by `@nif/gamebryo`.
local Skyrim = 'Gamebryo File Format, Version 20.2.0.7\n'
  .. u32(0x14020007)
  .. string.pack('<I1', 1)
  .. u32(12)
  .. u32(1)
  .. u32(83)
  .. short 'author\0'
  .. short 'process\0'
  .. short 'export\0'
  .. string.pack('<I2', 1)
  .. sized 'NiNode'
  .. string.pack('<I2', 0)
  .. u32(#SkyrimNode)
  .. u32(1)
  .. u32(10)
  .. sized 'Scene Root'
  .. u32(0)
  .. SkyrimNode
  .. u32(1)
  .. i32(0)

local ModelCount, KeyCount = 64, 4096

--- A fresh folder `name` under the scratch root.
local function folder(name: string): string
  local root = jess.fs.join(scratch, name)
  if jess.fs.exists(root) then assert(fs.remove(root, { recursive = true })) end

  jess.fs.createDir(root)
  return root
end

--- The data folder the checks read: the models, and the textures half of the built ones find.
local function dataFolder(): string
  local root = folder 'data'
  local function write(path: string, data: string | buffer)
    jess.fs.write(jess.fs.join(root, path), data)
  end

  for index = 1, ModelCount do
    local kind = index % 4
    local name = `model_{index}`
    local texture
    if kind == 0 then
      texture = `Textures\\Bench\\Tx_Stone_{index}.tga`
      write(`textures/bench/tx_stone_{index}.dds`, '')
    elseif kind == 1 then
      texture = `Tx_Wood_{index}.TGA`
      write(`textures/tx_wood_{index}.tga`, '')
    else
      texture = `Data Files\\Textures\\\\Tx_Gone_{index}.bmp`
    end

    write(
      `meshes/bench/{name}.nif`,
      if kind == 3 then defects(name, texture) else textured(name, texture)
    )
  end

  write('meshes/all_types.nif', asset 'all_types.nif')
  write('meshes/random_objects.nif', asset 'random_objects.nif')
  write('meshes/skyrim.nif', Skyrim)

  return root
end

local Extensions = table.freeze { 'nif', 'dds', 'tga', 'wav', 'kf', 'dds', 'mp3', 'dds' }

local Folders = table.freeze { 'meshes/x', 'textures', 'icons/m', 'sound/fx', 'meshes/r/xbase' }

--- A folder of `KeyCount` empty files to list, a quarter of them models and animations.
local function keyFolder(): string
  local root = folder 'keys'
  for index = 1, KeyCount do
    local place = Folders[index % #Folders + 1]
    local extension = Extensions[index % #Extensions + 1]
    jess.fs.write(jess.fs.join(root, `{place}/file_{index}.{extension}`), '')
  end

  return root
end

local DataRoot = dataFolder()
local KeyRoot = keyFolder()

local function mounted(root: string): vfs.VFS
  local made = vfs.VFS.new()
  made:pushDirectory(root)
  return made
end

local Data, Keys = mounted(DataRoot), mounted(KeyRoot)

--- Paths as records write them: mixed case, either separator, some already normal.
local function writtenPaths(count: number): { string }
  local paths = table.create(count) :: { string }
  for index = 1, count do
    local kind = index % 4
    if kind == 0 then
      paths[index] = `Textures\\Tx_Rock_{index}.tga`
    elseif kind == 1 then
      paths[index] = `meshes/x/ex_common_{index}.nif`
    elseif kind == 2 then
      paths[index] = `Data Files\\Textures\\\\TX_Wood_{index}.BMP`
    else
      paths[index] = `/BookArt/Scroll_{index}.dds`
    end
  end

  return paths
end

local Paths = writtenPaths(256)
local KeyList = Keys:keys():toTable()

workload('normalize 256 written paths', 6740, function(): number
  local total = 0
  for _, path in Paths do
    total += #assets.normalize(path)
  end

  return total
end, same)

workload('isNifPath over 4,096 keys', 1024, function(): number
  local found = 0
  for _, key in KeyList do
    if assets.isNifPath(key) then found += 1 end
  end

  return found
end, same)

do
  -- Every fourth texture is there as written, and every fourth only as a DDS.
  local present: { [string]: boolean } = {}
  for index, path in Paths do
    local resolved = assets.texturePath(path, function(): boolean return false end)
    if index % 4 == 0 then
      present[resolved.path] = true
    elseif index % 4 == 2 then
      present[resolved.tried[2]] = true
    end
  end

  local function exists(candidate: string): boolean return present[candidate] == true end

  workload('texturePath for 256 written paths', 582740, function(): number
    local total = 0
    for _, path in Paths do
      local resolved = assets.texturePath(path, exists)
      total += #resolved.tried * 1000 + #resolved.path
      if resolved.found then total += 1 end
    end

    return total
  end, same)
end

workload('new + addBase over 4,096 keys', 1024, function(): assets.Sources
  local made = assets.new(Keys)
  assets.addBase(made, assets.isNifPath)
  return made
end, function(made: assets.Sources): number return #made.targets end)

workload(
  'new + addVfsTarget for 64 models',
  ModelCount,
  function(): assets.Sources
    local made = assets.new(Data)
    for index = 1, ModelCount do
      assets.addVfsTarget(made, `Meshes\\Bench\\Model_{index}.NIF`)
    end

    return made
  end,
  function(made: assets.Sources): number return #made.targets end
)

local Checked = assets.sources(nil, nil, { DataRoot })

local function reportWeight(report: assets.CheckReport): number
  local total = report.summary.files * 1e6 + report.summary.wontLoad * 1e3 + #report.files
  for _, file in report.files do
    total += #file.findings * 10 + #file.textures
    for _, texture in file.textures do
      if texture.resolved then total += #texture.resolved end
    end
  end

  return total
end

workload(
  'check 67 models in a data folder',
  67002794,
  function(): assets.CheckReport return assets.check(Checked) end,
  reportWeight
)

local RandomObjects = buffer.fromstring(asset 'random_objects.nif')
local AllTypes = buffer.fromstring(asset 'all_types.nif')

workload('checkBytes random_objects', 0, function(): assets.FileReport
  return assets.checkBytes(Checked, 'meshes/random_objects.nif', 'memory', RandomObjects)
end, function(file: assets.FileReport): number return #file.findings * 10 + #file.textures end)

do
  -- The folder's report, forty times over: 2,680 files.
  local once = assets.check(Checked)
  local files = {}
  for _ = 1, 40 do
    table.move(once.files, 1, #once.files, #files + 1, files)
  end

  local large: assets.CheckReport = { summary = once.summary, files = files }

  workload(
    'shown: 2,680 files down to collision',
    67029600,
    function(): assets.CheckReport return assets.shown(large, 'collision', false) end,
    reportWeight
  )

  workload(
    'shown: 2,680 files, every file and finding',
    67072760,
    function(): assets.CheckReport return assets.shown(large, 'info', true) end,
    reportWeight
  )
end

local function infoWeight(report: assets.InfoReport): number
  local types = 0
  for _, count in report.recordTypes do
    types += count
  end

  return (report.recordCount or 0) * 1e6 + types * 1e3 + #report.tree * 10 + #report.textures
end

workload(
  'infoBytes all_types',
  85000000,
  function(): assets.InfoReport
    return assets.infoBytes(Checked, 'meshes/all_types.nif', 'memory', AllTypes)
  end,
  infoWeight
)

workload(
  'infoBytes random_objects',
  20020010,
  function(): assets.InfoReport
    return assets.infoBytes(Checked, 'meshes/random_objects.nif', 'memory', RandomObjects)
  end,
  infoWeight
)

workload(
  'info for 67 models in a data folder',
  67,
  function(): { assets.InfoReport } return assets.info(Checked) end,
  function(reports: { assets.InfoReport }): number return #reports end
)

local function target(path: string): assets.Target
  for _, found in Checked.targets do
    if found.path == path then return found end
  end

  return error(`nif-assets bench: no target {path}`, 0)
end

--- A dump's records and roots; where it came from is under the scratch folder.
local function dumpWeight(dump: assets.Dump): number
  return deepWeight(dump.records) + deepWeight(dump.roots)
end

local AllTypesTarget = target 'meshes/all_types.nif'
local RandomTarget = target 'meshes/random_objects.nif'
local SkyrimTarget = target 'meshes/skyrim.nif'

workload(
  'dump all_types',
  14201,
  function(): assets.Dump return assets.dump(Checked, AllTypesTarget) end,
  dumpWeight
)

workload(
  'dump random_objects',
  282873,
  function(): assets.Dump return assets.dump(Checked, RandomTarget) end,
  dumpWeight
)

workload(
  'dump random_objects, listed',
  454,
  function(): assets.Dump return assets.dump(Checked, RandomTarget, { list = true }) end,
  dumpWeight
)

workload(
  'dump all_types, shapes named tri',
  93,
  function(): assets.Dump
    return assets.dump(
      Checked,
      AllTypesTarget,
      { types = { 'nitrishape', 'NiNode' }, name = 'tri' }
    )
  end,
  dumpWeight
)

workload(
  'dump a Skyrim node',
  117,
  function(): assets.Dump return assets.dump(Checked, SkyrimTarget) end,
  dumpWeight
)

workload(
  'fix 67 models, dry run',
  67020816,
  function(): assets.FixReport return assets.fix(Checked, { dryRun = true }) end,
  function(report: assets.FixReport): number
    local total = report.summary.files * 1e6 + report.summary.fixed * 1e3 + #report.files
    for _, file in report.files do
      total += #file.fixes * 100
    end

    return total
  end
)

local Arguments: { { string } } = {
  { 'check', '--show', 'info', '--data', 'Data Files', '--data=Morrowind.bsa', 'meshes', 'x.nif' },
  { '--format', 'json', 'info', '--no-tree', '--data', 'Data Files', 'meshes/x/ex_common.nif' },
  { 'dump', '-t', 'NiNode', '-tNiTriShape', '--index', '4', '--index=7', '--name', '^tri', 'x' },
  { 'fix', '--only', 'rcn,ncc', '--only=markers', '--dry-run', '--output', 'fixed', '--', '-x' },
  { 'check', '-v', '--format=toml', 'one.nif', 'two.nif', 'three.nif', 'four.kf', 'five.nif' },
  { 'help', 'dump' },
  { 'dump', '--index', 'seven', 'x.nif' },
  { 'modify', '--script', 'edit.luau', 'x.nif' },
}

workload('parse 8 argument lists', 944, function(): number
  local parsed = 0
  for _, argv in Arguments do
    local command, message = cli.parse(argv)
    parsed += if command then 100 + #command.action else #(message :: string)
  end

  return parsed
end, same)

local Formats: { cli.Format } = { 'yaml', 'json', 'toml' }

--- Times a result's document in each format; `expected` holds the documents' weights in the
--- formats' order.
local function documents(name: string, result: commands.Result, expected: { number })
  for index, format in Formats do
    workload(
      `render {name} as {format}`,
      expected[index],
      function(): string return cli.render(result, { format = format }) end,
      textWeight
    )
  end
end

documents(
  'check of 67 models',
  commands.check { inputs = { DataRoot }, show = 'info', everyFile = true },
  { 4162360861308889, 3538546083278996, 3182455597084647 }
)

documents(
  'info of 67 models',
  commands.info { inputs = { DataRoot } },
  { 2157318466774763, 905538270462821, 3834447824752014 }
)

documents(
  'fix of 67 models',
  commands.fix { inputs = { DataRoot }, dryRun = true },
  { 165867822259026, 3661770337033038, 576250254990311 }
)

documents(
  'dump of all_types',
  commands.dump { input = `{DataRoot}/meshes/all_types.nif` },
  { 2579836550808924, 1364212260565166, 3305734554042671 }
)

documents(
  'dump of random_objects',
  commands.dump { input = `{DataRoot}/meshes/random_objects.nif` },
  { 3008505421982011, 3480015347812338, 386778157929975 }
)

workload(
  'check command: sources, check, shown, YAML',
  46095758551344,
  function(): string
    local result = commands.check { inputs = { DataRoot }, data = { KeyRoot } }
    return cli.render(result, { format = 'yaml' })
  end,
  textWeight
)

--- Times the command line run once on `argv`, a process a sample. What it prints must weigh
--- `expected`, and it must exit with `status`.
local function cold(name: string, expected: number, status: number, argv: { string })
  if not binary or (only and not string.find(name, only, 1, true)) then return end

  local arguments = {
    'run',
    '--capability',
    'filesystem.read',
    '--package',
    `{Here}/..`,
    '--package-path',
    PackagePath,
    `{Here}/cold.luau`,
  }

  for _, argument in argv do
    table.insert(arguments, argument)
  end

  local samples = {}
  for run = 1, 7 do
    local result, message = process.run(binary, arguments, { stdout = 'capture', stderr = 'null' })
    if not result then error(`{name}: {message}`, 0) end

    local printed = result.stdout or ''
    local document, code, seconds = string.match(printed, '^(.*)\n(%d+)\t([%d.]+)\n$')
    local weight = if document then textWeight(document) else -1
    if tonumber(code) ~= status or weight ~= expected then
      error(`{name}: exited {code} having printed {weight}, not {status} and {expected}`, 0)
    end

    samples[run] = tonumber(seconds) :: number
  end

  print(`{name}\t{string.format('%.9f', median(samples))}`)
end

cold('cold: help', 613667570714215, 0, { 'help' })
cold('cold: check of 67 models', 46095758551344, 1, { 'check', DataRoot })
cold(
  'cold: dump of random_objects',
  3008505421982011,
  0,
  { 'dump', `{DataRoot}/meshes/random_objects.nif` }
)

assert(fs.remove(DataRoot, { recursive = true }))
assert(fs.remove(KeyRoot, { recursive = true }))

