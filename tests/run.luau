--!strict
--!native
-- nif-assets' cases, on data folders and an archive built in scratch: NIFs made with `@nif`'s
-- editing API (a plain shape, and one with the defects the check and the fixes know), the two
-- NetImmerse files jess-nif tested with (`assets/`), and textures that are only names, since a
-- lookup never opens one. Reports are pinned whole wherever they are small enough to read.
local archive = require '@dream-archive'
local assets = require '@nif-assets'
local check = require '@nif/check'
local nif = require '@nif'
local test = require '@jess/test'
local vfs = require '@vfs'

local expect = test.expect
local suite = test.new()
local scratch = assert(rawget(_G, 'scratchRoot') :: string?, 'the suite needs a host-owned scratchRoot')

--- Where this file is, from its chunk name: the folder the suite and its assets are in.
local function here(): string
  local source = debug.info(1, 's')
  local first = string.sub(source, 1, 1)
  local path = if first == '@' or first == '=' then string.sub(source, 2) else source

  return string.match(path, '^(.*)/[^/]*$') or '.'
end

local Here = here()

local function asset(name: string): string
  local path = `{Here}/assets/{name}`
  return jess.fs.read(path) or error(`can't read {path}`, 0)
end

local AllTypes, RandomObjects = asset 'all_types.nif', asset 'random_objects.nif'

local Triangle = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } }

--- A triangle under a root node, drawn with `texture` when one is named.
local function shape(texture: string?): buffer
  local file = nif.new()
  local root = file:insert { type = 'NiNode', name = 'Root' }
  file:shape {
    name = 'Tri Shape',
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
local function defects(): buffer
  local file = nif.new()
  local root = file:insert { type = 'NiNode', name = 'Root' }
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
    texture = 'Textures\\Tx_Gone.tga',
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

local IdentityRows = string.rep(f32(1) .. f32(0) .. f32(0) .. f32(0), 2) .. f32(1)

--- A Skyrim file (20.2.0.7, user version 12, stream 83) holding one `NiNode`, as `@nif`'s own
--- suite writes it: a model of another game, which the check reads and nothing here edits.
local SkyrimNode = i32(0)
  .. u32(0)
  .. i32(-1)
  .. u32(14)
  .. f32(1)
  .. f32(2)
  .. f32(3)
  .. IdentityRows
  .. f32(1)
  .. i32(-1)
  .. u32(0)
  .. u32(0)

local SkyrimFile = 'Gamebryo File Format, Version 20.2.0.7\n'
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

--- A fresh folder under the scratch root holding `files` by their paths below it.
local function tree(name: string, files: { [string]: string | buffer }): string
  local root = jess.fs.join(scratch, 'nif-assets', name)
  if jess.fs.exists(root) then jess.fs.remove(root) end

  jess.fs.createDir(root)
  for path, data in files do
    jess.fs.write(jess.fs.join(root, path), data)
  end

  return root
end

--- A Morrowind archive at `path` holding `files` by their VFS paths.
local function pack(path: string, files: { [string]: string | buffer })
  local builder = archive.bsa.tes3.Builder.new()
  local names = {}
  for name in files do
    table.insert(names, name)
  end

  table.sort(names)
  for _, name in names do
    local data = files[name]
    builder:addBytes(name, if type(data) == 'string' then data else buffer.tostring(data))
  end

  builder:writePath(path)
end

local NoStats: check.Stats = {
  records = 0,
  reachableRecords = 0,
  nodes = 0,
  shapes = 0,
  vertices = 0,
  triangles = 0,
  collisionTriangles = 0,
  controllers = 0,
  embeddedTextures = 0,
  embeddedTextureBytes = 0,
  skinned = false,
}

local function stats(counts: { [string]: number }): check.Stats
  local made = table.clone(NoStats) :: { [string]: unknown }
  for key, value in counts do
    made[key] = value
  end

  return (made :: unknown) :: check.Stats
end

local ShapeStats = stats {
  records = 5,
  reachableRecords = 5,
  nodes = 1,
  shapes = 1,
  vertices = 3,
  triangles = 1,
  collisionTriangles = 1,
}

local DefectStats = stats {
  records = 8,
  reachableRecords = 8,
  nodes = 3,
  shapes = 1,
  vertices = 3,
  triangles = 1,
}

local VisibleMarker: assets.FindingReport = {
  severity = 'broken',
  code = 'visibleEditorMarker',
  message = '"Tri EditorMarker 0" draws in game because the root has no "MRK" string data',
  record = 7,
}

local MissingTexture: assets.FindingReport = {
  severity = 'missingAsset',
  code = 'missingTexture',
  message = 'texture "Textures\\Tx_Gone.tga" not found (tried textures/tx_gone.dds, textures/tx_gone.tga)',
}

local LowercaseNcc: assets.FindingReport = {
  severity = 'collision',
  code = 'lowercaseNcc',
  message = '"NCc" turns collision off entirely; only an uppercase "NCC" keeps camera collision',
  record = 1,
}

local InvalidHeader: assets.FindingReport = {
  severity = 'wontLoad',
  code = 'invalidHeader',
  message = 'truncated version line at offset 0',
}

--- A lookup over the paths listed.
local function among(files: { string }): (string) -> boolean
  return function(path: string): boolean return table.find(files, path) ~= nil end
end

local function paths<Item>(items: { Item & { path: string } }): { string }
  local out = {}
  for _, item in items do
    table.insert(out, item.path)
  end

  return out
end

--- The mod most cases read: two models and a file that isn't one under `Meshes/x`, a model
--- elsewhere under `Meshes`, and the one texture the plain shape names, as a `.dds`.
local function mod(name: string): string
  return tree(name, {
    ['mod/Meshes/x/shape.nif'] = shape 'textures\\tx_a.tga',
    ['mod/Meshes/x/defects.nif'] = defects(),
    ['mod/Meshes/x/junk.nif'] = 'not a model',
    ['mod/Meshes/y/idle.kf'] = shape(),
    ['mod/Meshes/y/notes.txt'] = 'not a model either',
    ['mod/textures/tx_a.dds'] = 'a texture',
  })
end

suite.describe('paths', function()
  suite.it('are spelled as OpenMW\'s VFS spells them', function()
    expect(assets.normalize '\\Textures\\\\Tx_Foo.TGA').toBe 'textures/tx_foo.tga'
    expect(assets.normalize '//a//b/').toBe 'a/b/'
    expect(assets.normalize 'meshes/x.nif').toBe 'meshes/x.nif'
  end)

  suite.it('name a model or an animation by their extension, in any case', function()
    expect(assets.isNifPath 'meshes/x/a.nif').toBe(true)
    expect(assets.isNifPath 'Meshes\\X\\A.NIF').toBe(true)
    expect(assets.isNifPath 'meshes/x/xa.kf').toBe(true)
    expect(assets.isNifPath 'meshes/x/a.nif.bak').toBe(false)
    expect(assets.isNifPath 'textures/a.dds').toBe(false)
  end)
end)

-- `correctTexturePath` (components/misc/resourcehelpers.cpp), case by case as jess-assets held it.
suite.describe('texture lookup', function()
  suite.it('prefers a .dds under the textures directory', function()
    expect(assets.texturePath('tx_foo.tga', among { 'textures/tx_foo.dds' })).toEqual {
      path = 'textures/tx_foo.dds',
      found = true,
      tried = { 'textures/tx_foo.dds' },
    }

    expect(assets.texturePath('tx_foo.tga', among { 'textures/tx_foo.tga' })).toEqual {
      path = 'textures/tx_foo.tga',
      found = true,
      tried = { 'textures/tx_foo.dds', 'textures/tx_foo.tga' },
    }
  end)

  suite.it('strips everything before a directory it knows', function()
    local resolved =
      assets.texturePath('C:\\Data Files\\Textures\\a\\b.bmp', among { 'textures/a/b.dds' })
    expect(resolved.path).toBe 'textures/a/b.dds'
    expect(resolved.found).toBe(true)

    -- `bookart` is the second directory a texture may already be under.
    expect(assets.texturePath('x/BookArt/map.tga', among { 'bookart/map.dds' }).path).toBe 'bookart/map.dds'

    -- A known directory at the very end stops the search, so the path is prefixed.
    expect(assets.texturePath('stuff/textures', among {})).toEqual {
      path = 'textures/stuff/textures',
      found = false,
      tried = { 'textures/stuff/textures', 'textures/textures' },
    }
  end)

  suite.it('falls back to the file name directly under textures', function()
    expect(assets.texturePath('a/b/tx_foo.tga', among { 'textures/tx_foo.tga' })).toEqual {
      path = 'textures/tx_foo.tga',
      found = true,
      tried = {
        'textures/a/b/tx_foo.dds',
        'textures/a/b/tx_foo.tga',
        'textures/tx_foo.dds',
        'textures/tx_foo.tga',
      },
    }
  end)

  suite.it('answers the .dds path for a texture nothing has', function()
    expect(assets.texturePath('tx_gone.tga', among {})).toEqual {
      path = 'textures/tx_gone.dds',
      found = false,
      tried = { 'textures/tx_gone.dds', 'textures/tx_gone.tga' },
    }
  end)

  suite.it('is correctResourcePath over the directories and extension given', function()
    expect(assets.resourcePath({ 'icons' }, 'm\\coin.tga', 'dds', among {}).tried).toEqual {
      'icons/m/coin.dds',
      'icons/m/coin.tga',
      'icons/coin.dds',
      'icons/coin.tga',
    }

    -- Without a preferred extension, only the path and the bare file name are tried.
    expect(assets.resourcePath({ 'icons' }, 'm\\coin.tga', nil, among { 'icons/coin.tga' })).toEqual {
      path = 'icons/coin.tga',
      found = true,
      tried = { 'icons/m/coin.tga', 'icons/coin.tga' },
    }
  end)
end)

suite.describe('sources', function()
  suite.it('bring a NIF\'s data folder along when it is in a meshes folder', function()
    local root = mod 'meshes-folder'
    local file = jess.fs.join(root, 'mod/Meshes/x/shape.nif')
    local made = assets.sources(nil, nil, { file })
    expect(made.targets).toEqual { { path = 'meshes/x/shape.nif', source = file, layer = 1 } }
    expect(#made.inputs).toBe(1)
    expect(made.inputs[1].name).toBe(jess.fs.join(root, 'mod'))
    expect(made.base).toBeNil()

    -- So the texture beside its meshes folder is found, and nothing else is read.
    expect(assets.sourceOf(made, 'textures/tx_a.dds')).toBe(jess.fs.join(root, 'mod/textures/tx_a.dds'))
    expect(assets.targetFile(made, made.targets[1])).toBe(file)
    expect(buffer.tostring(assets.readTarget(made, made.targets[1]))).toBe(
      buffer.tostring(shape 'textures\\tx_a.tga')
    )
  end)

  suite.it('read a NIF outside any meshes folder alone, by its file name', function()
    local root = tree('lone', { ['Lone/Plain.NIF'] = shape 'tx_plain.bmp' })
    local file = jess.fs.join(root, 'Lone/Plain.NIF')
    local made = assets.sources(nil, nil, { file })
    expect(made.targets).toEqual { { path = 'plain.nif', source = file, layer = -1 } }
    expect(made.inputs).toEqual {}
    expect(assets.targetFile(made, made.targets[1])).toBe(file)
    expect(assets.sourceOf(made, 'plain.nif')).toBeNil()
  end)

  suite.it('read the models and animations under a folder, in path order', function()
    local root = mod 'folder'
    local data = jess.fs.join(root, 'mod')
    local everything = assets.sources(nil, nil, { jess.fs.join(data, 'Meshes') })
    expect(everything.targets).toEqual {
      { path = 'meshes/x/defects.nif', source = data, layer = 1 },
      { path = 'meshes/x/junk.nif', source = data, layer = 1 },
      { path = 'meshes/x/shape.nif', source = data, layer = 1 },
      { path = 'meshes/y/idle.kf', source = data, layer = 1 },
    }

    -- Only what is under the folder given is read, though its whole data folder is searched.
    local under = assets.sources(nil, nil, { jess.fs.join(data, 'Meshes/y') })
    expect(paths(under.targets)).toEqual { 'meshes/y/idle.kf' }
    expect(under.inputs[1].name).toBe(data)

    -- A folder with no meshes folder above it is its own data folder.
    local whole = assets.sources(nil, nil, { data })
    expect(#whole.targets).toBe(4)
    expect(whole.inputs[1].name).toBe(data)
  end)

  suite.it('read the models an archive holds', function()
    local root = tree('archive', {})
    local path = jess.fs.join(root, 'Pack.bsa')
    pack(path, {
      ['meshes/a/packed.nif'] = shape 'tx_only.tga',
      ['textures/tx_only.dds'] = 'archived',
    })

    local made = assets.sources(nil, nil, { path })
    expect(made.targets).toEqual { { path = 'meshes/a/packed.nif', source = path, layer = 1 } }
    expect(assets.sourceOf(made, 'textures/tx_only.dds')).toBe(path)
    expect(assets.targetFile(made, made.targets[1])).toBeNil()
    expect(buffer.tostring(assets.readTarget(made, made.targets[1]))).toBe(
      buffer.tostring(shape 'tx_only.tga')
    )
  end)

  suite.it('read every model of the load order when no input is given', function()
    local root = tree('load-order', {
      ['data/meshes/b/loose.nif'] = shape(),
      ['data/textures/tx_a.dds'] = 'loose',
    })
    local data = jess.fs.join(root, 'data')
    pack(jess.fs.join(data, 'Pack.bsa'), {
      ['meshes/a/packed.nif'] = shape(),
      ['textures/tx_a.dds'] = 'archived',
    })

    local base = vfs.VFS.fromDirectories({ data }, { archives = { 'Pack.bsa' } })
    local made = assets.sources(base)
    expect(made.targets).toEqual {
      { path = 'meshes/a/packed.nif', source = jess.fs.join(data, 'Pack.bsa'), layer = 0 },
      { path = 'meshes/b/loose.nif', source = jess.fs.join(data, 'meshes/b/loose.nif'), layer = 0 },
    }
    expect(made.inputs).toEqual {}

    -- A loose file wins over the archive's copy of it.
    expect(assets.sourceOf(made, 'textures/tx_a.dds')).toBe(jess.fs.join(data, 'textures/tx_a.dds'))
    expect(assets.targetFile(made, made.targets[1])).toBeNil()
    expect(assets.targetFile(made, made.targets[2])).toBe(jess.fs.join(data, 'meshes/b/loose.nif'))
  end)

  suite.it('find a VFS path in the load order, and put inputs over it', function()
    local root = tree('layers', {
      ['data/meshes/b/loose.nif'] = shape(),
      ['data/textures/tx_a.dds'] = 'base',
      ['data/textures/tx_base.dds'] = 'base',
      ['first/textures/tx_a.dds'] = 'first',
      ['first/textures/tx_first.dds'] = 'first',
      ['second/textures/tx_a.dds'] = 'second',
    })
    local data = jess.fs.join(root, 'data')
    local base = vfs.VFS.fromDirectories { data }
    local first, second = jess.fs.join(root, 'first'), jess.fs.join(root, 'second')
    local made = assets.sources(base, { first, second, first }, { 'Meshes\\B\\Loose.nif' })
    expect(made.targets).toEqual {
      { path = 'meshes/b/loose.nif', source = jess.fs.join(data, 'meshes/b/loose.nif'), layer = 0 },
    }

    -- Data folders are only searched, later ones first, and one given twice is there once.
    expect(#made.inputs).toBe(2)
    expect(assets.sourceOf(made, 'textures/tx_a.dds')).toBe(jess.fs.join(second, 'textures/tx_a.dds'))
    expect(assets.sourceOf(made, 'textures/tx_first.dds')).toBe(
      jess.fs.join(first, 'textures/tx_first.dds')
    )
    expect(assets.sourceOf(made, 'textures/tx_base.dds')).toBe(jess.fs.join(data, 'textures/tx_base.dds'))
    expect(assets.sourceOf(made, 'textures/tx_none.dds')).toBeNil()

    -- A path is a target once, and one nothing holds is not a target at all.
    expect(assets.addVfsTarget(made, 'meshes/b/loose.nif')).toBe(true)
    expect(assets.addVfsTarget(made, 'meshes/b/none.nif')).toBe(false)
    expect(#made.targets).toBe(1)
  end)

  suite.it('refuse what is not there and what is not a NIF', function()
    local root = mod 'refusals'
    local notes = jess.fs.join(root, 'mod/Meshes/y/notes.txt')
    local nowhere = jess.fs.join(root, 'nowhere.nif')
    expect(function() assets.sources(nil, nil, { notes }) end).toThrow(
      `'{notes}' isn't a directory, NIF, KF, or archive`
    )
    expect(function() assets.sources(nil, nil, { nowhere }) end).toThrow(`'{nowhere}' doesn't exist`)
    expect(function() assets.sources(nil, { notes }) end).toThrow(
      `'{notes}' isn't a directory, NIF, KF, or archive`
    )
    expect(function() assets.sources(nil, { nowhere }) end).toThrow(`'{nowhere}' doesn't exist`)

    -- A file named as an archive that isn't one.
    local fake = jess.fs.join(root, 'Fake.bsa')
    jess.fs.write(fake, 'not an archive')
    expect(function() assets.sources(nil, nil, { fake }) end).toThrow(
      `'{fake}' isn't a directory, NIF, KF, or archive`
    )
  end)
end)

suite.describe('check', function()
  suite.it('reports each model with its textures looked up in its own data folder', function()
    local root = mod 'check'
    local data = jess.fs.join(root, 'mod')
    local report = assets.check(assets.sources(nil, nil, { jess.fs.join(data, 'Meshes/x') }))
    expect(report).toEqual {
      summary = {
        texturesChecked = true,
        loadOrderChecked = false,
        files = 3,
        deeplyChecked = 2,
        wontLoad = 1,
        byWorstSeverity = { broken = 1, wontLoad = 1 },
        byCode = {
          invalidHeader = 1,
          lowercaseNcc = 1,
          missingTexture = 1,
          visibleEditorMarker = 1,
        },
      },
      files = {
        {
          path = 'meshes/x/defects.nif',
          source = data,
          version = '4.0.0.2',
          game = 'Morrowind',
          deeplyChecked = true,
          worst = 'broken',
          -- Most severe first: the missing texture, about no record, sits between the two the
          -- check itself found.
          findings = { VisibleMarker, MissingTexture, LowercaseNcc },
          textures = { { path = 'Textures\\Tx_Gone.tga' } },
          stats = DefectStats,
        },
        {
          path = 'meshes/x/junk.nif',
          source = data,
          deeplyChecked = false,
          worst = 'wontLoad',
          findings = { InvalidHeader },
          textures = {},
        },
        {
          path = 'meshes/x/shape.nif',
          source = data,
          version = '4.0.0.2',
          game = 'Morrowind',
          deeplyChecked = true,
          findings = {},
          textures = {
            {
              path = 'textures\\tx_a.tga',
              resolved = 'textures/tx_a.dds',
              source = jess.fs.join(data, 'textures/tx_a.dds'),
            },
          },
          stats = ShapeStats,
        },
      },
    }
  end)

  suite.it('finds a texture in the load order, loose before archived, and says when it isn\'t a .dds', function()
    local root = tree('check-order', {
      ['data/meshes/loose.nif'] = shape 'tx_both.tga',
      ['data/meshes/plain.nif'] = shape 'sub\\tx_plain.bmp',
      ['data/textures/tx_both.dds'] = 'loose',
      ['data/textures/tx_plain.bmp'] = 'loose',
    })
    local data = jess.fs.join(root, 'data')
    local packed = jess.fs.join(data, 'Pack.bsa')
    pack(packed, {
      ['meshes/packed.nif'] = shape 'tx_only.tga',
      ['textures/tx_both.dds'] = 'archived',
      ['textures/tx_only.dds'] = 'archived',
    })

    local base = vfs.VFS.fromDirectories({ data }, { archives = { 'Pack.bsa' } })
    local report = assets.check(assets.sources(base))
    expect(report.summary).toEqual {
      texturesChecked = true,
      loadOrderChecked = true,
      files = 3,
      deeplyChecked = 3,
      wontLoad = 0,
      byWorstSeverity = { performance = 1 },
      byCode = { uncompressedTexture = 1 },
    }

    local loose, archived, plain = report.files[1], report.files[2], report.files[3]
    expect(loose.path).toBe 'meshes/loose.nif'
    expect(loose.source).toBe(jess.fs.join(data, 'meshes/loose.nif'))
    expect(loose.findings).toEqual {}
    expect(loose.textures).toEqual {
      {
        path = 'tx_both.tga',
        resolved = 'textures/tx_both.dds',
        source = jess.fs.join(data, 'textures/tx_both.dds'),
      },
    }

    expect(archived.path).toBe 'meshes/packed.nif'
    expect(archived.source).toBe(packed)
    expect(archived.textures).toEqual {
      { path = 'tx_only.tga', resolved = 'textures/tx_only.dds', source = packed },
    }

    -- Found by its file name directly under textures, as the format it was written in.
    expect(plain.worst).toBe 'performance'
    expect(plain.findings).toEqual {
      {
        severity = 'performance',
        code = 'uncompressedTexture',
        message = '"textures/tx_plain.bmp" isn\'t a DDS file, so it loads uncompressed and has its mipmaps built at load time',
      },
    }

    expect(plain.textures).toEqual {
      {
        path = 'sub\\tx_plain.bmp',
        resolved = 'textures/tx_plain.bmp',
        source = jess.fs.join(data, 'textures/tx_plain.bmp'),
      },
    }
  end)

  suite.it('lists a lone NIF\'s textures without looking them up', function()
    local root = tree('check-lone', { ['plain.nif'] = shape 'tx_plain.bmp' })
    local file = jess.fs.join(root, 'plain.nif')
    expect(assets.check(assets.sources(nil, nil, { file }))).toEqual {
      summary = {
        texturesChecked = false,
        loadOrderChecked = false,
        files = 1,
        deeplyChecked = 1,
        wontLoad = 0,
        byWorstSeverity = {},
        byCode = {},
      },
      files = {
        {
          path = 'plain.nif',
          source = file,
          version = '4.0.0.2',
          game = 'Morrowind',
          deeplyChecked = true,
          findings = {},
          textures = { { path = 'tx_plain.bmp' } },
          stats = ShapeStats,
        },
      },
    }
  end)

  suite.it('reports the fixtures as jess-nif\'s check does, and another game\'s model', function()
    local root = tree('check-fixtures', {
      ['meshes/all_types.nif'] = AllTypes,
      ['meshes/random_objects.nif'] = RandomObjects,
      ['meshes/skyrim.nif'] = SkyrimFile,
    })
    local report = assets.check(assets.sources(nil, nil, { jess.fs.join(root, 'meshes') }))
    expect(report.summary).toEqual {
      texturesChecked = true,
      loadOrderChecked = false,
      files = 3,
      deeplyChecked = 2,
      wontLoad = 1,
      byWorstSeverity = { info = 1, wontLoad = 1 },
      byCode = { rootTransformIgnored = 1, unknownRecordType = 1 },
    }

    local allTypes, randomObjects, skyrim = report.files[1], report.files[2], report.files[3]
    expect(allTypes.findings).toEqual {
      {
        severity = 'wontLoad',
        code = 'unknownRecordType',
        message = 'Unknown record type NiBltSource',
        record = 1,
      },
    }
    expect(allTypes.stats).toBeNil()
    expect(randomObjects.findings).toEqual {}
    expect(randomObjects.worst).toBeNil()
    expect(randomObjects.stats).toEqual(stats {
      records = 20,
      reachableRecords = 20,
      nodes = 3,
      shapes = 8,
      vertices = 8818,
      triangles = 4214,
      collisionTriangles = 4214,
    })

    expect(skyrim.version).toBe '20.2.0.7'
    expect(skyrim.game).toBe 'Skyrim'
    expect(skyrim.findings).toEqual {
      {
        severity = 'info',
        code = 'rootTransformIgnored',
        message = 'the root node "Scene Root" has a transform, which OpenMW ignores like Morrowind does',
        record = 0,
      },
    }
  end)

  suite.it('checks bytes it is handed against the sources', function()
    local root = mod 'check-bytes'
    local made = assets.sources(nil, { jess.fs.join(root, 'mod') }, { jess.fs.join(root, 'mod/Meshes/y') })
    local report = assets.checkBytes(made, 'meshes/new.nif', 'memory', shape 'tx_a.bmp')
    expect(report.path).toBe 'meshes/new.nif'
    expect(report.source).toBe 'memory'
    expect(report.findings).toEqual {}
    expect(report.textures).toEqual {
      {
        path = 'tx_a.bmp',
        resolved = 'textures/tx_a.dds',
        source = jess.fs.join(root, 'mod/textures/tx_a.dds'),
      },
    }
  end)

  suite.it('says a model that has gone can\'t be read', function()
    local root = mod 'check-gone'
    local lone = tree('check-gone-lone', { ['plain.nif'] = shape() })
    local folder = assets.sources(nil, nil, { jess.fs.join(root, 'mod/Meshes/y') })
    local file = assets.sources(nil, nil, { jess.fs.join(lone, 'plain.nif') })
    jess.fs.remove(jess.fs.join(root, 'mod/Meshes/y/idle.kf'))
    jess.fs.remove(jess.fs.join(lone, 'plain.nif'))

    local gone = assets.check(folder)
    expect(gone.summary.wontLoad).toBe(1)
    expect(gone.summary.deeplyChecked).toBe(0)
    expect(gone.files).toEqual {
      {
        path = 'meshes/y/idle.kf',
        source = jess.fs.join(root, 'mod'),
        deeplyChecked = false,
        worst = 'wontLoad',
        findings = {
          {
            severity = 'wontLoad',
            code = 'unreadableFile',
            message = 'failed to read: dream.vfs: No such file or directory (os error 2)',
          },
        },
        textures = {},
      },
    }

    expect(assets.check(file).files[1].findings).toEqual {
      {
        severity = 'wontLoad',
        code = 'unreadableFile',
        message = 'failed to read: plain.nif: file not found',
      },
    }
  end)

  suite.it('shows a report down to a severity, counting everything still', function()
    local root = mod 'shown'
    local report = assets.check(assets.sources(nil, nil, { jess.fs.join(root, 'mod/Meshes/x') }))
    local broken = assets.shown(report, 'broken', false)
    expect(broken.summary).toBe(report.summary)
    expect(paths(broken.files)).toEqual { 'meshes/x/defects.nif', 'meshes/x/junk.nif' }
    expect(broken.files[1].findings).toEqual { VisibleMarker }
    expect(broken.files[1].worst).toBe 'broken'
    expect(broken.files[2].findings).toEqual { InvalidHeader }

    -- The report it was made from is left whole.
    expect(report.files[1].findings).toEqual { VisibleMarker, MissingTexture, LowercaseNcc }

    local missing = assets.shown(report, 'missingAsset', false)
    expect(missing.files[1].findings).toEqual { VisibleMarker, MissingTexture }

    local every = assets.shown(report, 'wontLoad', true)
    expect(#every.files).toBe(3)
    expect(every.files[1].findings).toEqual {}
    expect(every.files[3].findings).toEqual {}
    expect(#assets.shown(report, 'info', false).files).toBe(2)
  end)
end)

suite.describe('info', function()
  suite.it('describes each model: header, records, collision, textures, and scene graph', function()
    local root = mod 'info'
    local data = jess.fs.join(root, 'mod')
    local reports = assets.info(assets.sources(nil, nil, { jess.fs.join(data, 'Meshes/x') }))
    expect(#reports).toBe(3)
    expect(reports[1]).toEqual {
      path = 'meshes/x/defects.nif',
      source = data,
      version = '4.0.0.2',
      game = 'Morrowind',
      userVersion = 0,
      recordCount = 8,
      recordTypes = {
        NiNode = 2,
        NiSourceTexture = 1,
        NiStringExtraData = 1,
        NiTexturingProperty = 1,
        NiTriShape = 1,
        NiTriShapeData = 1,
        RootCollisionNode = 1,
      },
      collision = { source = 'none', hidesMarkers = false },
      stats = DefectStats,
      textures = { { path = 'Textures\\Tx_Gone.tga' } },
      tree = {
        {
          index = 0,
          type = 'NiNode',
          name = 'Root',
          extraData = { { index = 1, type = 'NiStringExtraData', value = 'NCc' } },
          children = {
            {
              index = 2,
              type = 'NiNode',
              name = 'Inner',
              children = { { index = 3, type = 'RootCollisionNode', name = 'RootCollisionNode' } },
            },
            {
              index = 7,
              type = 'NiTriShape',
              name = 'Tri EditorMarker 0',
              properties = { { index = 6, type = 'NiTexturingProperty' } },
              shape = {
                data = { index = 4, type = 'NiTriShapeData' },
                vertices = 3,
                triangles = 1,
              },
            },
          },
        },
      },
    }

    expect(reports[2]).toEqual {
      path = 'meshes/x/junk.nif',
      source = data,
      recordTypes = {},
      error = 'truncated version line at offset 0',
      textures = {},
      tree = {},
    }

    local plain = reports[3]
    expect(plain.collision).toEqual { source = 'renderGeometry', hidesMarkers = false }
    expect(plain.stats).toEqual(ShapeStats)
    expect(plain.textures).toEqual {
      {
        path = 'textures\\tx_a.tga',
        resolved = 'textures/tx_a.dds',
        source = jess.fs.join(data, 'textures/tx_a.dds'),
      },
    }
  end)

  suite.it('says why OpenMW won\'t load a file, counting records where the header lists them', function()
    local made = assets.sources()

    -- A NetImmerse 4.0.0.2 header has no type table, so there is nothing to count.
    expect(assets.infoBytes(made, 'all_types.nif', 'memory', buffer.fromstring(AllTypes))).toEqual {
      path = 'all_types.nif',
      source = 'memory',
      version = '4.0.0.2',
      game = 'Morrowind',
      userVersion = 0,
      recordCount = 85,
      recordTypes = {},
      error = 'Unknown record type NiBltSource',
      textures = {},
      tree = {},
    }

    local unknown = string.gsub(SkyrimFile, 'NiNode', 'XiNode', 1)
    local report = assets.infoBytes(made, 'unknown.nif', 'memory', buffer.fromstring(unknown))
    expect(report.error).toBe 'Unknown record type XiNode'
    expect(report.recordCount).toBe(1)
    expect(report.recordTypes).toEqual { XiNode = 1 }
    expect(report.author).toBe 'author'
    expect(report.tree).toEqual {}
    expect(report.stats).toBeNil()
    expect(report.collision).toBeNil()
  end)

  suite.it('reads random_objects.nif and another game\'s model through their own readers', function()
    local made = assets.sources()
    local random =
      assets.infoBytes(made, 'random_objects.nif', 'memory', buffer.fromstring(RandomObjects))
    expect(random.error).toBeNil()
    expect(random.recordCount).toBe(20)
    expect(random.recordTypes).toEqual {
      NiMaterialProperty = 1,
      NiNode = 3,
      NiTriShape = 8,
      NiTriShapeData = 7,
      NiWireframeProperty = 1,
    }
    expect(#random.tree).toBe(1)
    expect(random.collision).toEqual { source = 'renderGeometry', hidesMarkers = false }

    local skyrim = assets.infoBytes(made, 'skyrim.nif', 'memory', buffer.fromstring(SkyrimFile))
    expect(skyrim.version).toBe '20.2.0.7'
    expect(skyrim.game).toBe 'Skyrim'
    expect(skyrim.userVersion).toBe(12)
    expect(skyrim.bethVersion).toBe(83)
    expect(skyrim.recordTypes).toEqual { NiNode = 1 }
    expect(skyrim.collision).toEqual { source = 'none', hidesMarkers = false }
    expect(#skyrim.tree).toBe(1)
    expect(skyrim.tree[1].name).toBe 'Scene Root'
  end)

  suite.it('says a model that has gone can\'t be read', function()
    local root = tree('info-gone', { ['plain.nif'] = shape() })
    local file = jess.fs.join(root, 'plain.nif')
    local made = assets.sources(nil, nil, { file })
    jess.fs.remove(file)
    expect(assets.info(made)).toEqual {
      {
        path = 'plain.nif',
        source = file,
        recordTypes = {},
        error = 'failed to read: plain.nif: file not found',
        textures = {},
        tree = {},
      },
    }
  end)
end)

local Fixes = {
  { fix = 'ncc', message = '"NCc" is now "NCC", so the camera still collides', record = 1 },
  {
    fix = 'rcn',
    message = 'added "RCN" string data, so OpenMW finds the RootCollisionNode (record 3) under a child node',
    record = 0,
  },
  {
    fix = 'markers',
    message = 'added "MRK" string data, so 1 editor marker shape doesn\'t draw in game',
    record = 0,
  },
}

--- The codes the check finds in the model at `path`.
local function codes(path: string): { string }
  local report = check.check(path, assert(jess.fs.readBuffer(path)))
  local out = {}
  for _, finding in report.findings do
    table.insert(out, finding.code)
  end

  return out
end

suite.describe('fix', function()
  suite.it('reports what it would change without writing', function()
    local root = mod 'fix-dry'
    local data = jess.fs.join(root, 'mod')
    local file = jess.fs.join(data, 'Meshes/x/defects.nif')
    local before = jess.fs.read(file)
    local report = assets.fix(assets.sources(nil, nil, { jess.fs.join(data, 'Meshes') }), { dryRun = true })
    expect(report).toEqual {
      summary = {
        files = 4,
        fixed = 1,
        written = 0,
        skipped = 1,
        byFix = { markers = 1, ncc = 1, rcn = 1 },
      },
      -- Only the files that need a fix, or couldn't be read for one.
      files = {
        { path = 'meshes/x/defects.nif', source = data, fixes = Fixes },
        {
          path = 'meshes/x/junk.nif',
          source = data,
          fixes = {},
          skipped = 'meshes/x/junk.nif: truncated version line at offset 0',
        },
      },
    }
    expect(jess.fs.read(file)).toBe(before)
    expect(jess.fs.exists(file .. '.bak')).toBe(false)
  end)

  suite.it('writes over the file, backing it up first', function()
    local root = mod 'fix-backup'
    local data = jess.fs.join(root, 'mod')
    local file = jess.fs.join(data, 'Meshes/x/defects.nif')
    local before = jess.fs.read(file)
    expect(codes(file)).toEqual { 'visible_editor_marker', 'lowercase_ncc' }

    local report = assets.fix(assets.sources(nil, nil, { file }))
    expect(report).toEqual {
      summary = {
        files = 1,
        fixed = 1,
        written = 1,
        skipped = 0,
        byFix = { markers = 1, ncc = 1, rcn = 1 },
      },
      files = {
        {
          path = 'meshes/x/defects.nif',
          source = file,
          fixes = Fixes,
          written = { path = file, backup = file .. '.bak' },
        },
      },
    }
    expect(jess.fs.read(file .. '.bak')).toBe(before)
    expect(codes(file)).toEqual {}

    -- Fixed, there is nothing left to fix, and nothing is written again.
    local again = assets.fix(assets.sources(nil, nil, { file }))
    expect(again.files).toEqual {}
    expect(again.summary).toEqual { files = 1, fixed = 0, written = 0, skipped = 0, byFix = {} }
  end)

  suite.it('writes over the file without a backup when told to', function()
    local root = mod 'fix-plain'
    local file = jess.fs.join(root, 'mod/Meshes/x/defects.nif')
    local report = assets.fix(assets.sources(nil, nil, { file }), { backup = false })
    expect(report.files[1].written).toEqual { path = file }
    expect(jess.fs.exists(file .. '.bak')).toBe(false)
    expect(codes(file)).toEqual {}
  end)

  suite.it('makes only the fixes asked for', function()
    local root = mod 'fix-only'
    local file = jess.fs.join(root, 'mod/Meshes/x/defects.nif')
    local report = assets.fix(assets.sources(nil, nil, { file }), { only = { 'ncc' }, backup = false })
    expect(report.files[1].fixes).toEqual { Fixes[1] }
    expect(report.summary.byFix).toEqual { ncc = 1 }
    expect(codes(file)).toEqual { 'visible_editor_marker' }
  end)

  suite.it('writes into an output folder at the VFS path, leaving the original', function()
    local root = mod 'fix-output'
    local data = jess.fs.join(root, 'mod')
    local file = jess.fs.join(data, 'Meshes/x/defects.nif')
    local before = jess.fs.read(file)
    local output = jess.fs.join(root, 'fixed')
    local report = assets.fix(assets.sources(nil, nil, { file }), { output = output })
    local written = jess.fs.join(output, 'meshes/x/defects.nif')
    expect(report.files[1].written).toEqual { path = written }
    expect(jess.fs.read(file)).toBe(before)
    expect(codes(written)).toEqual {}
  end)

  suite.it('skips a model in an archive unless it has somewhere to write it', function()
    local root = tree('fix-archive', {})
    local path = jess.fs.join(root, 'Pack.bsa')
    pack(path, { ['meshes/a/defects.nif'] = defects(), ['meshes/a/skyrim.nif'] = SkyrimFile })

    local report = assets.fix(assets.sources(nil, nil, { path }))
    expect(report).toEqual {
      -- Another game's model is read by the check alone, so it is never listed for a fix.
      summary = {
        files = 2,
        fixed = 0,
        written = 0,
        skipped = 1,
        byFix = { markers = 1, ncc = 1, rcn = 1 },
      },
      files = {
        {
          path = 'meshes/a/defects.nif',
          source = path,
          fixes = Fixes,
          skipped = 'it\'s in an archive; use --output to write fixed files to a folder',
        },
      },
    }

    local output = jess.fs.join(root, 'fixed')
    local extracted = assets.fix(assets.sources(nil, nil, { path }), { output = output })
    local written = jess.fs.join(output, 'meshes/a/defects.nif')
    expect(extracted.summary.written).toBe(1)
    expect(extracted.files[1].written).toEqual { path = written }
    expect(codes(written)).toEqual {}
  end)
end)

return suite
