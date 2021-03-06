-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

--[[
# Lua Sandbox Utility Module

## Functions

### behead_array

Effectively removes all array values up to the provided index from an array
by copying end values to the array head and setting now unused entries at
the end of the array to `nil`.

*Arguments*
- index (number) - remove the values in the array up to the index value
- array (table) - array to behead

*Return*
- none - in-place operation

### pairs_by_key

Sorts the keys into an array, and then iterates on the array.

*Arguments*
- hash (table) - hash table to iterate in sorted key order
- sort (function) - function to specify an alternate sort order

*Return*
- function - iterator that traverses the table keys in sort function order


### merge_objects
Merge two objects. Add all data from "src" to "dest". Numeric values are added,
boolean and string values are overwritten, and arrays and objects are
recursively merged. Any data with different types in dest and src will be
skipped.

#### Example

```lua
local a = {
    foo = 1,
    bar = {1, 1, 3},
    quux = 3
}
local b = {
    foo = 5,
    bar = {0, 0, 5, 1},
    baz = {
        hello = 100
    }
}

local c = merge_objects(a, b)
-------
 c contains {
    foo = 6,
    bar = {1, 1, 8, 1},
    baz = {
        hello = 100
    },
    quux = 3
}
```
--]]

-- Imports
local pairs = pairs
local table = require "table"
local type = type

local M = {}
setfenv(1, M) -- Remove external access to contain everything in the module

function behead_array(idx, array)
    if idx <= 1 then return end
    local array_len = #array
    local start_nil_idx = 1 -- If idx > #array we zero it out completely.
    if idx <= array_len then
        -- Copy values to lower indexes.
        local difference = idx - 1
        for i = idx, array_len do
            array[i-difference] = array[i]
        end
        start_nil_idx = array_len - difference + 1
    end
    -- Empty out the end of the array.
    for i = start_nil_idx, array_len do
        array[i] = nil
    end
end

-- http://www.lua.org/pil/19.3.html
function pairs_by_key(t, f)
    local a = {}
    for n in pairs(t) do table.insert(a, n) end
    table.sort(a, f)
    local i = 0                -- iterator variable
    local iter = function ()   -- iterator function
        i = i + 1
        if a[i] == nil then
            return nil
        else
            return a[i], t[a[i]]
        end
    end
    return iter
end


function merge_objects(dest, src)
    if dest == nil then
        return src
    end
    if src == nil then
        return dest
    end

    local tdest = type(dest)
    local tsrc = type(src)

    -- Types are different. Ignore the src value, because src is wrong.
    if tdest ~= tsrc then
        return dest
    end

    -- types are the same, neither is nil.
    if tdest == "number" then
        return dest + src
    end

    -- most recent wins:
    if tdest == "boolean" or tdest == "string" then
        return src
    end

    if tdest == "table" then
        -- array or object, iterate by key
        for k,v in pairs(src) do
            dest[k] = merge_objects(dest[k], v)
        end
        return dest
    end

    return dest -- unmergable type, leave as-is
end

return M
