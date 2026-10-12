--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A record's fields as plain data. `@nif` and `@nif/gamebryo` hold bulk data as views of the file's
bytes and coordinates as `vector`s, each with its own way of being read; here they become lists
of numbers, so a record can be walked, compared, or written out by something that knows neither
reader. Strings, numbers, and booleans are themselves, a struct is a table by field name, and a
list is a list.
]]

--- The array kinds whose elements `toTable` hands over as a `vector` with only two components
--- set: texture coordinates, and a vertex with its weight.
local Pairs: { [string]: boolean } = table.freeze { vec2 = true, u16f32 = true }

--- What every `@nif` array view answers to.
type View = { kind: string, toTable: (self: View) -> { unknown } }

local function components(value: vector, width: number): { number }
  if width == 2 then return { value.x, value.y } end

  return { value.x, value.y, value.z }
end

local function bytesOf(bytes: buffer): { number }
  local length = buffer.len(bytes)
  local list = table.create(length) :: { number }
  for index = 1, length do
    list[index] = buffer.readu8(bytes, index - 1)
  end

  return list
end

--- `value` as plain data; a `vector` gives `width` components, three unless told otherwise.
local function plain(value: unknown, width: number?): unknown
  local kind = typeof(value)
  if kind == 'vector' then return components(value :: vector, width or 3) end

  if kind == 'buffer' then return bytesOf(value :: buffer) end

  if kind ~= 'table' then return value end

  local fields = value :: { [unknown]: unknown }
  local meta = getmetatable(fields :: {}) :: { [string]: unknown }?
  if meta and type(rawget(fields, 'stride')) == 'number' then
    local view = (value :: unknown) :: View
    -- An array view: its `toTable` is the kind's own reading of every element.
    if type(view.toTable) == 'function' then
      local each = if Pairs[view.kind] then 2 else 3
      local elements = view:toTable()
      local list = table.create(#elements) :: { unknown }
      for index, element in elements do
        list[index] = if typeof(element) == 'vector'
          then components(element :: vector, each)
          else plain(element, each)
      end

      return list
    end
  end

  -- A list `@nif/gamebryo` reads an element at a time answers `#` and an index, and nothing else.
  if meta and meta.__len then
    local rows = value :: { unknown }
    local list = table.create(#rows) :: { unknown }
    for index = 1, #rows do
      list[index] = plain(rows[index])
    end

    return list
  end

  local named = false
  for key in fields do
    if type(key) ~= 'number' then
      named = true
      break
    end
  end

  if not named then
    local items = value :: { unknown }
    local list = table.create(#items) :: { unknown }
    for index, item in items do
      list[index] = plain(item)
    end

    return list
  end

  local out: { [string]: unknown } = {}
  for key, field in fields do
    out[tostring(key)] = plain(field)
  end

  return out
end

return table.freeze { plain = plain }
