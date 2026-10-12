--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A command's result as the document `jess nif` printed for it: the same fields in the same order,
field names and codes in snake_case (`wont_load`, `missing_texture`), an absent value as `null`
in YAML and JSON and left out of TOML. Data in, text out: nothing here opens a file. The one
absent value TOML can't leave out is a dump's root that names no record, an entry of a list:
that is -1 there, where `jess nif dump` failed with "unsupported None value".

YAML and TOML documents end with a line break of their own, and JSON is one line with one added,
so a document goes to standard output exactly as it is returned.

A dump's records are the one place the original can't be matched field for field. `@nif` holds a
record as a table by field name, with no order among its fields and nothing saying which numbers
are floats, so a record is written `index`, `type`, `name`, then its other fields by name, and a
float with no fraction is written as a whole number.
]]

local commands = require './commands'
local listing = require './listing'
local serialize = require '@jess/data/value'

type Value = serialize.Value

export type Format = 'yaml' | 'json' | 'toml'

--- `camelCase` as `camel_case`: jess's `symbol::snake_case`, which leaves a leading capital be.
local function snake(name: string): string
  local rest = string.gsub(
    string.sub(name, 2),
    '%u',
    function(letter: string): string return `_{string.lower(letter)}` end
  )
  return string.sub(name, 1, 1) .. rest
end

local function list<Item>(items: { Item }, each: (Item) -> Value): Value
  return serialize.array([for entry in items => each(entry)])
end

--- Counts by code, the codes in snake_case and in their order: a `BTreeMap` of them.
local function counts(byCode: { [string]: number }): Value
  local spelled: { [string]: number }, names = {}, {}
  for code, count in byCode do
    local name = snake(code)
    spelled[name] = count
    table.insert(names, name)
  end

  table.sort(names)
  local out = serialize.map()
  for _, name in names do
    serialize.set(out, name, spelled[name])
  end

  return out
end

--- Counts by a name that is data, not a code, in the names' order.
local function tally(byName: { [string]: number }): Value
  local names = {}
  for name in byName do
    table.insert(names, name)
  end

  table.sort(names)
  local out = serialize.map()
  for _, name in names do
    serialize.set(out, name, byName[name])
  end

  return out
end

type Stats = {
  records: number,
  reachableRecords: number,
  nodes: number,
  shapes: number,
  vertices: number,
  triangles: number,
  collisionTriangles: number,
  controllers: number,
  embeddedTextures: number,
  embeddedTextureBytes: number,
  skinned: boolean,
}

local function stats(found: Stats?): Value
  if not found then return serialize.None end

  return serialize.struct {
    { 'records', found.records },
    { 'reachable_records', found.reachableRecords },
    { 'nodes', found.nodes },
    { 'shapes', found.shapes },
    { 'vertices', found.vertices },
    { 'triangles', found.triangles },
    { 'collision_triangles', found.collisionTriangles },
    { 'controllers', found.controllers },
    { 'embedded_textures', found.embeddedTextures },
    { 'embedded_texture_bytes', found.embeddedTextureBytes },
    { 'skinned', found.skinned },
  }
end

type Texture = { path: string, resolved: string?, source: string? }

local function texture(found: Texture): Value
  return serialize.struct {
    { 'path', found.path },
    { 'resolved', found.resolved },
    { 'source', found.source },
  }
end

local function check(result: commands.CheckResult): Value
  local summary = result.report.summary
  return serialize.struct {
    {
      'summary',
      serialize.struct {
        { 'textures_checked', summary.texturesChecked },
        { 'load_order_checked', summary.loadOrderChecked },
        { 'files', summary.files },
        { 'deeply_checked', summary.deeplyChecked },
        { 'wont_load', summary.wontLoad },
        { 'by_worst_severity', counts(summary.byWorstSeverity) },
        { 'by_code', counts(summary.byCode) },
      },
    },
    {
      'files',
      list(result.report.files, function(file): Value
        return serialize.struct {
          { 'path', file.path },
          { 'source', file.source },
          { 'version', file.version },
          { 'game', file.game },
          { 'deeply_checked', file.deeplyChecked },
          { 'worst', if file.worst then snake(file.worst) else nil },
          {
            'findings',
            list(file.findings, function(finding): Value
              return serialize.struct {
                { 'severity', snake(finding.severity) },
                { 'code', snake(finding.code) },
                { 'message', finding.message },
                { 'record', finding.record },
              }
            end),
          },
          { 'textures', list(file.textures, texture) },
          { 'stats', stats(file.stats) },
        }
      end),
    },
  }
end

type RecordRef = { index: number, type: string }

local function recordRef(found: RecordRef): Value
  return serialize.struct { { 'index', found.index }, { 'type', found.type } }
end

type TreeNode = {
  index: number,
  type: string,
  name: string,
  hidden: boolean?,
  controllers: { { index: number, type: string, active: boolean } }?,
  properties: { RecordRef }?,
  effects: { RecordRef }?,
  extraData: { { index: number, type: string, value: string? } }?,
  collision: RecordRef?,
  shape: { data: RecordRef?, vertices: number, triangles: number, skin: number? }?,
  children: { TreeNode }?,
}

--- A node of the scene graph. What it doesn't have is left out, not written as null, apart from
--- a shape's data and skin.
local function treeNode(node: TreeNode): Value
  local fields: { { unknown } } = {
    { 'index', node.index },
    { 'type', node.type },
    { 'name', node.name },
  }

  if node.hidden then table.insert(fields, { 'hidden', true }) end

  if node.controllers and #node.controllers > 0 then
    table.insert(fields, {
      'controllers',
      list(node.controllers, function(controller): Value
        return serialize.struct {
          { 'index', controller.index },
          { 'type', controller.type },
          { 'active', controller.active },
        }
      end),
    })
  end

  if node.properties and #node.properties > 0 then
    table.insert(fields, { 'properties', list(node.properties, recordRef) })
  end

  if node.effects and #node.effects > 0 then
    table.insert(fields, { 'effects', list(node.effects, recordRef) })
  end

  if node.extraData and #node.extraData > 0 then
    table.insert(fields, {
      'extra_data',
      list(node.extraData, function(extra): Value
        local entry: { { unknown } } = { { 'index', extra.index }, { 'type', extra.type } }
        if extra.value then table.insert(entry, { 'value', extra.value }) end

        return serialize.struct(entry)
      end),
    })
  end

  if node.collision then table.insert(fields, { 'collision', recordRef(node.collision) }) end

  local shape = node.shape
  if shape then
    table.insert(fields, {
      'shape',
      serialize.struct {
        { 'data', if shape.data then recordRef(shape.data) else nil },
        { 'vertices', shape.vertices },
        { 'triangles', shape.triangles },
        { 'skin', shape.skin },
      },
    })
  end

  if node.children and #node.children > 0 then
    table.insert(fields, { 'children', list(node.children, treeNode) })
  end

  return serialize.struct(fields)
end

local function info(result: commands.InfoResult): Value
  return serialize.struct {
    {
      'files',
      list(result.files, function(file): Value
        local collision: Value = serialize.None
        local found = file.collision
        if found then
          local fields: { { unknown } } = {
            { 'source', snake(found.source) },
            { 'node', found.node },
            { 'hides_markers', found.hidesMarkers },
          }

          if found.bsxFlags then table.insert(fields, { 'bsx_flags', found.bsxFlags }) end

          collision = serialize.struct(fields)
        end

        return serialize.struct {
          { 'path', file.path },
          { 'source', file.source },
          { 'version', file.version },
          { 'game', file.game },
          { 'user_version', file.userVersion },
          { 'beth_version', file.bethVersion },
          { 'author', file.author },
          { 'record_count', file.recordCount },
          { 'record_types', tally(file.recordTypes) },
          { 'error', file.error },
          { 'collision', collision },
          { 'stats', stats(file.stats) },
          { 'textures', list(file.textures, texture) },
          { 'tree', list(file.tree, treeNode) },
        }
      end),
    },
  }
end

local function fix(result: commands.FixResult): Value
  local summary = result.report.summary
  return serialize.struct {
    {
      'summary',
      serialize.struct {
        { 'files', summary.files },
        { 'fixed', summary.fixed },
        { 'written', summary.written },
        { 'skipped', summary.skipped },
        { 'by_fix', counts(summary.byFix) },
      },
    },
    {
      'files',
      list(result.report.files, function(file): Value
        local written = file.written
        return serialize.struct {
          { 'path', file.path },
          { 'source', file.source },
          {
            'fixes',
            list(file.fixes, function(fixed): Value
              return serialize.struct {
                { 'fix', snake(fixed.fix) },
                { 'message', fixed.message },
                { 'record', fixed.record },
              }
            end),
          },
          {
            'written',
            if written
              then serialize.struct { { 'path', written.path }, { 'backup', written.backup } }
              else nil,
          },
          { 'skipped', file.skipped },
        }
      end),
    },
  }
end

local function modify(result: commands.ModifyResult): Value
  local fields: { { unknown } } = {
    { 'input', result.input },
    { 'path', result.path },
    { 'script', result.script },
    { 'changed', result.changed },
  }

  if result.dryRun then table.insert(fields, { 'dry_run', true }) end

  local written = result.written
  if written then
    local file: { { unknown } } = { { 'path', written.path } }
    if written.backup then table.insert(file, { 'backup', written.backup }) end

    table.insert(fields, { 'written', serialize.struct(file) })
  else
    table.insert(fields, { 'written', nil })
  end

  return serialize.struct(fields)
end

--- The fields a record starts with, in this order, when it has them.
local Leading = table.freeze { 'index', 'type', 'name' }

--- A record's plain data as a value: a list as an array, and a table by field name as a map of
--- its fields in snake_case, the leading ones first when `record`, the rest by name.
local function plainValue(plain: unknown, record: boolean): Value
  if plain == nil then return serialize.None end

  if type(plain) ~= 'table' then
    local kind = typeof(plain)
    if kind == 'number' or kind == 'string' or kind == 'boolean' or kind == 'integer' then
      return plain
    end

    return tostring(plain)
  end

  local fields = plain :: { [unknown]: unknown }
  if next(fields) == nil or fields[1] ~= nil then
    -- A table with a first entry is a list whatever else it holds, so every entry it has is
    -- walked, under the key it is at.
    local entries = plain :: { unknown }
    local out = table.create(#entries) :: { Value }
    for index, entry in entries do
      out[index] = plainValue(entry, false)
    end

    return serialize.array(out)
  end

  local names: { string }, byName: { [string]: unknown } = {}, {}
  for key, field in fields do
    local name = snake(tostring(key))
    byName[name] = field
    if not (record and table.find(Leading, name)) then table.insert(names, name) end
  end

  table.sort(names)
  local out = serialize.map()
  if record then
    for _, name in Leading do
      if byName[name] ~= nil then serialize.set(out, name, plainValue(byName[name], false)) end
    end
  end

  for _, name in names do
    serialize.set(out, name, plainValue(byName[name], false))
  end

  return out
end

--- The fields before a dump's records: where the NIF is from, and its roots by record index. A
--- root that names no record is null, except in TOML, which has no null and can't leave an entry
--- out of a list without moving the ones after it: there it is -1, as the file itself spells it.
local function dumpHeader(result: commands.DumpResult, format: Format): serialize.Map
  return serialize.struct {
    { 'path', result.path },
    { 'source', result.source },
    {
      'roots',
      list(result.roots, function(root: number): Value
        return if root >= 0 or format == 'toml' then root else serialize.None
      end),
    },
  }
end

--- A dump: its header, then `records`. In YAML the records are written by jess's own list
--- writer, as `jess nif dump` streamed them.
local function dump(result: commands.DumpResult, format: Format): string
  local header = dumpHeader(result, format)
  local records = [for record in result.records => plainValue(record, true)]
  if format ~= 'yaml' then
    serialize.set(header, 'records', serialize.array(records))
    return serialize.encode(header, format) .. (if format == 'json' then '\n' else '')
  end

  local opening = serialize.encode(header, 'yaml')
  if #records == 0 then return `{opening}records: []\n` end

  local items = [for record in records => listing.item(record)]
  return `{opening}records:\n{table.concat(items)}`
end

--- A result's document as a value, for every command whose document serde wrote whole.
local function document(result: commands.Result): Value
  if result.command == 'check' then return check(result) end

  if result.command == 'info' then return info(result) end

  if result.command == 'fix' then return fix(result) end

  if result.command == 'modify' then return modify(result) end

  return error(`no document for a {result.command} result`, 0)
end

--- The result as the text the original printed for it, in `format` (YAML without one).
local function render(result: commands.Result, format: Format?): string
  local chosen: Format = format or 'yaml'
  if result.command == 'dump' then return dump(result, chosen) end

  local text = serialize.encode(document(result), chosen)
  return if chosen == 'json' then `{text}\n` else text
end

return table.freeze { render = render }
