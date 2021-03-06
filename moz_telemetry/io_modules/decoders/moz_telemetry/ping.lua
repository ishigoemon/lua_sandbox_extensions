-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

--[[
# Mozilla Telemetry Ping Decoder Module

## Decoder Configuration Table
```lua
decoders_moz_telemetry_ping = {
    -- String used to specify the schema location on disk. The path should
    -- contain one directory for each docType and the files in the directory
    -- must be named <docType>.<version>.schema.json. If the schema file is not
    -- found for a docType/version combination, the default schema is used to
    -- verify the document is a valid json object.
    -- e.g., main/main.4.schema.json
    schema_path = "/mnt/work/mozilla-pipeline-schemas/schemas/telemetry",

    -- String used to specify the message field containing the user submitted telemetry ping.
    content_field = "Fields[content]", -- optional, default shown

    -- String used to specify the message field containing the URI of the submitted telemetry ping.
    uri_field = "Fields[uri]", -- optional, default shown

    -- String used to specify GeoIP city database location on disk.
    city_db_file = "/mnt/work/geoip/city.db", -- optional, if not specified no geoip lookup is performed

    -- Boolean used to determine whether to inject the raw message in addition to the decoded one.
    inject_raw = false, -- optional, if not specified the raw message is not injected

    -- WARNING if the cuckoo filter settings are altered the plugin's
    -- `preservation_version` should be incremented
    -- number of items in each de-duping cuckoo filter partition
    cf_items = 32e6, -- optional, if not provided de-duping is disabled

    -- number of partitions, each containing `cf_items`
    -- cf_partitions = 4 -- optional default 4 (1, 2, 4, 8, 16)

    -- interval size in minutes for cuckoo filter pruning
    -- cf_interval_size = 6, -- optional, default 6 (25.6 hours)
}
```

## Functions

### transform_message

Transform and inject the message using the provided stream reader.

*Arguments*
- hsr (hsr) - stream reader with the message to process

*Return*
- none, injects an error message on decode failure

### decode

Decode and inject the message given as argument, using a module-internal stream reader.

*Arguments*
- msg (string) - binary message to decode

*Return*
- none, injects an error message on decode failure
--]]

_PRESERVATION_VERSION = read_config("preservation_version") or _PRESERVATION_VERSION or 0

-- Imports
local module_name   = ...
local string        = require "string"
local table         = require "table"
local module_cfg    = string.gsub(module_name, "%.", "_")

local rjson  = require "rjson"
local io     = require "io"
local lfs    = require "lfs"
local lpeg   = require "lpeg"
local table  = require "table"
local os     = require "os"
local floor  = require "math".floor
local crc32  = require "zlib".crc32
local mtn    = require "moz_telemetry.normalize"
local dt     = require "lpeg.date_time"

local read_config          = read_config
local assert               = assert
local error                = error
local pairs                = pairs
local ipairs               = ipairs
local create_stream_reader = create_stream_reader
local decode_message       = decode_message
local inject_message       = inject_message
local type                 = type
local tonumber             = tonumber
local tostring             = tostring
local pcall                = pcall
local geoip
local city_db
local dedupe
local duplicateDelta

-- create before the environment is locked down since it conditionally includes a module
local function load_decoder_cfg()
    local cfg = read_config(module_cfg)
    assert(type(cfg) == "table", module_cfg .. " must be a table")
    assert(type(cfg.schema_path) == "string", "schema_path must be set")

    -- the old values for these were Fields[submission] and Fields[Path]
    if not cfg.content_field then cfg.content_field = "Fields[content]" end
    if not cfg.uri_field then cfg.uri_field = "Fields[uri]" end
    if not cfg.inject_raw then cfg.inject_raw = false end
    assert(type(cfg.inject_raw) == "boolean", "inject_raw must be a boolean")

    if cfg.cf_items then
        if not cfg.cf_interval_size then cfg.cf_interval_size = 6 end
        if cfg.cf_partitions then
            local x = cfg.cf_partitions
            assert(type(cfg.cf_partitions) == "number" and x == 1 or x == 2 or x == 4 or x == 8 or x == 16,
                    "cf_partitions [1,2,4,8,16]")
        else
            cfg.cf_partitions = 4
        end
        local cfe = require "cuckoo_filter_expire"
        dedupe = {}
        for i=1, cfg.cf_partitions do
            local name = "g_mtp_dedupe" .. tostring(i)
            _G[name] = cfe.new(cfg.cf_items, cfg.cf_interval_size) -- global scope so they can be preserved
            dedupe[i] = _G[name] -- use a local array for access
                                 -- optimization to reduce the restoration memory allocation and time
        end
        duplicateDelta = {value_type = 2, value = 0, representation = tostring(cfg.cf_interval_size) .. "m"}
    end

    if cfg.city_db_file then
        geoip = require "geoip.city"
        city_db = assert(geoip.open(cfg.city_db_file))
    end

    return cfg
end

local M = {}
setfenv(1, M) -- Remove external access to contain everything in the module

local cfg = load_decoder_cfg()
local UNK_DIM = "UNKNOWN"
local UNK_GEO = "??"
-- Track the hour to facilitate reopening city_db hourly.
local hour = floor(os.time() / 3600)

local function get_geo_field(xff, remote_addr, field_name, default_value)
    local geo
    if xff then
        local first_addr = string.match(xff, "([^, ]+)")
        if first_addr then
            geo = city_db:query_by_addr(first_addr, field_name)
        end
    end
    if geo then return geo end
    if remote_addr then
        geo = city_db:query_by_addr(remote_addr, field_name)
    end
    return geo or default_value
end

local function get_geo_country(xff, remote_addr)
    return get_geo_field(xff, remote_addr, "country_code", UNK_GEO)
end

local function get_geo_city(xff, remote_addr)
    return get_geo_field(xff, remote_addr, "city", UNK_GEO)
end

local schemas = {}
local default_schema = rjson.parse_schema([[
{
  "$schema" : "http://json-schema.org/draft-04/schema#",
  "type" : "object",
  "title" : "default_schema",
  "properties" : {
  },
  "required" : []
}
]])

local function load_schemas()
    for dn in lfs.dir(cfg.schema_path) do
        local fqdn = string.format("%s/%s", cfg.schema_path, dn)
        local mode = lfs.attributes(fqdn, "mode")
        if mode == "directory" and not dn:match("^%.") then
            for fn in lfs.dir(fqdn) do
                local name, version = fn:match("(.+)%.(%d+).schema%.json$")
                if name then
                    local fh = assert(io.input(string.format("%s/%s", fqdn, fn)))
                    local schema = fh:read("*a")
                    local s = schemas[name]
                    if not s then
                        s = {}
                        schemas[name] = s
                    end
                    local ok, rjs = pcall(rjson.parse_schema, schema)
                    if not ok then error(string.format("%s: %s", fn, rjs)) end
                    s[tonumber(version)] = rjs
                end
            end
        end
    end
end
load_schemas()

local uri_config = {
    telemetry = {
        dimensions      = {"docType","appName","appVersion","appUpdateChannel","appBuildId"},
        max_path_length = 10240,
        },
    }

local extract_payload_objects = {
    main = {
        "addonDetails",
        "addonHistograms",
        "childPayloads", -- only present with e10s
        "chromeHangs",
        "fileIOReports",
        "histograms",
        "info",
        "keyedHistograms",
        "lateWrites",
        "log",
        "simpleMeasurements",
        "slowSQL",
        "slowSQLstartup",
        "threadHangStats",
        "UIMeasurements",
        "gc",
        },
    }
extract_payload_objects["saved-session"] = extract_payload_objects["main"]

local environment_objects = {
    "addons",
    "build",
    "experiments",
    "partner",
    "profile",
    "settings",
    "system",
    }

--[[
Read the raw message, annotate it with our error information, and attempt to inject it.
--]]
local function inject_error(hsr, err_type, err_msg, extra_fields)
    local len
    local raw = hsr:read_message("raw")
    local err = decode_message(raw)
    err.Logger = "telemetry"
    err.Type = "telemetry.error"
    if not err.Fields then
        err.Fields = {}
    else
        len = #err.Fields
        for i = len, 1, -1  do
            local name = err.Fields[i].name
            if name == "X-Forwarded-For" or name == "RemoteAddr" then
                table.remove(err.Fields, i)
            end
        end
    end
    len = #err.Fields
    if not extra_fields or not extra_fields.submissionDate then
        len = len + 1
        err.Fields[len] = { name="submissionDate", value=os.date("%Y%m%d", err.Timestamp / 1e9) }
    end
    len = len + 1
    err.Fields[len] = { name="DecodeErrorType", value=err_type }
    len = len + 1
    err.Fields[len] = { name="DecodeError",     value=err_msg }

    if extra_fields then
        -- Add these optional fields to the raw message.
        for k,v in pairs(extra_fields) do
            len = len + 1
            err.Fields[len] = { name=k, value=v }
        end
    end
    pcall(inject_message, err)
end

--[[
Split a path into components. Multiple consecutive separators do not
result in empty path components.
Examples:
  /foo/bar      ->   {"foo", "bar"}
  ///foo//bar/  ->   {"foo", "bar"}
  foo/bar/      ->   {"foo", "bar"}
  /             ->   {}
--]]
local sep           = lpeg.P("/")
local elem          = lpeg.C((1 - sep)^1)
local path_grammar  = lpeg.Ct(elem^0 * (sep^0 * elem)^0)
local hsr           = create_stream_reader("decoders.moz_telemetry.ping")

local function split_path(s)
    if type(s) ~= "string" then return {} end
    return lpeg.match(path_grammar, s)
end


local function process_uri(hsr)
    -- Path should be of the form: ^/submit/namespace/id[/extra/path/components]$
    local path = hsr:read_message(cfg.uri_field)

    local components = split_path(path)
    if not components or #components < 3 then
        inject_error(hsr, "uri", "Not enough path components")
        return
    end

    local submit = table.remove(components, 1)
    if submit ~= "submit" then
        inject_error(hsr, "uri", string.format("Invalid path prefix: '%s' in %s", submit, path))
        return
    end

    local namespace = table.remove(components, 1)
    local ucfg = uri_config[namespace]
    if not ucfg then
        inject_error(hsr, "uri", string.format("Invalid namespace: '%s' in %s", namespace, path))
        return
    end

    local pathLength = string.len(path)
    if pathLength > ucfg.max_path_length then
        inject_error(hsr, "uri", string.format("Path too long: %d > %d", pathLength, ucfg.max_path_length))
        return
    end

    local msg = {
        Timestamp = hsr:read_message("Timestamp"),
        Logger    = ucfg.logger or namespace,
        Fields    = {
            documentId  = table.remove(components, 1),
            geoCountry  = hsr:read_message("Fields[geoCountry]"),
            geoCity     = hsr:read_message("Fields[geoCity]")
            }
        }

    -- insert geo info if necessary
    if city_db and not msg.Fields.geoCountry then
        local xff = hsr:read_message("Fields[X-Forwarded-For]")
        local remote_addr = hsr:read_message("Fields[RemoteAddr]")
        msg.Fields.geoCountry = get_geo_country(xff, remote_addr)
        msg.Fields.geoCity = get_geo_city(xff, remote_addr)
    end

    local num_components = #components
    if num_components > 0 then
        local dims = ucfg.dimensions
        if dims and #dims >= num_components then
            for i=1,num_components do
                msg.Fields[dims[i]] = components[i]
            end
        else
            inject_error(hsr, "uri", "dimension spec/path component mismatch", msg.Fields)
            return
        end
    end
    msg.Fields.normalizedChannel = mtn.channel(msg.Fields.appUpdateChannel)

    if dedupe then
        local int = string.byte(msg.Fields.documentId)
        if int > 96 then
            int = int - 39
        elseif int > 64 then
            int = int - 7
        end
        local idx = int % cfg.cf_partitions + 1
        local cf = dedupe[idx]
        local added, delta = cf:add(msg.Fields.documentId, msg.Timestamp)
        if not added then
            msg.Type = "telemetry.duplicate"
            duplicateDelta.value = delta
            msg.Fields.duplicateDelta = duplicateDelta
            pcall(inject_message, msg)
            return
        end
    end

    return msg
end


local function remove_objects(msg, doc, section, objects)
    if type(objects) ~= "table" then return end

    local v = doc:find(section)
    if not v then return end

    for i, name in ipairs(objects) do
        local fieldname = string.format("%s.%s", section, name)
        msg.Fields[fieldname] = doc:make_field(doc:remove_shallow(v, name))
    end
end


local function validate_schema(hsr, msg, doc, version)
    local schema = default_schema
    local dt = schemas[msg.Fields.docType or ""]
    if dt then
        version = tonumber(version)
        if not version then version = 1 end
        schema = dt[version] or default_schema
    end

    ok, err = doc:validate(schema)
    if not ok then
        inject_error(hsr, "json", string.format("%s schema version %s validation error: %s", msg.Fields.docType, tostring(version), err), msg.Fields)
        return false
    end
    return true
end


local submissionField = {value = nil, representation = "json"}
local doc = rjson.parse("{}") -- reuse this object to avoid creating a lot of GC
local function process_json(hsr, msg)
    local ok, err = pcall(doc.parse_message, doc, hsr, cfg.content_field, nil, nil, true)
    if not ok then
        -- TODO: check for gzip errors and classify them properly
        inject_error(hsr, "json", string.format("invalid submission: %s", err), msg.Fields)
        return false
    end

    local clientId
    local ver = doc:value(doc:find("ver"))

    if ver then
        if not validate_schema(hsr, msg, doc, ver) then return false end
        if ver == 3 then
            -- Special case for FxOS FTU pings
            submissionField.value = doc
            msg.Fields.submission = submissionField
            msg.Fields.sourceVersion = tostring(ver)
        else
            -- Old-style telemetry.
            local info = doc:find(info)
            -- the info object should exist because we passed schema validation (maybe)
            -- if type(info) == nil then
            --     inject_error(hsr, "schema", string.format("missing info object"), msg.Fields)
            -- end
            submissionField.value = doc
            msg.Fields.submission = submissionField
            msg.Fields.sourceVersion = tostring(ver)

            -- Get some more dimensions.
            msg.Fields.docType           = doc:value(doc:find(info, "reason")) or UNK_DIM
            msg.Fields.appName           = doc:value(doc:find(info, "appName")) or UNK_DIM
            msg.Fields.appVersion        = doc:value(doc:find(info, "appVersion")) or UNK_DIM
            msg.Fields.appUpdateChannel  = doc:value(doc:find(info, "appUpdateChannel")) or UNK_DIM
            msg.Fields.appBuildId        = doc:value(doc:find(info, "appBuildID")) or UNK_DIM
            msg.Fields.normalizedChannel = mtn.channel(doc:value(doc:find(info, "appUpdateChannel")))

            -- Old telemetry was always "enabled"
            msg.Fields.telemetryEnabled = true

            -- Do not want default values for these.
            msg.Fields.os = doc:value(doc:find(info, "OS"))
            msg.Fields.appVendor = doc:value(doc:find(info, "vendor"))
            msg.Fields.reason = doc:value(doc:find(info, "reason"))
            clientId = doc:value(doc:find("clientID")) -- uppercase ID is correct
            msg.Fields.clientId = clientId
        end
    elseif doc:value(doc:find("version")) then
        -- new code
        local sourceVersion = doc:value(doc:find("version"))
        if not validate_schema(hsr, msg, doc, sourceVersion) then return false end
        submissionField.value = doc
        msg.Fields.submission = submissionField
        local cts = doc:value(doc:find("creationDate"))
        if cts then
            msg.Fields.creationTimestamp = dt.time_to_ns(dt.rfc3339:match(cts))
        end
        msg.Fields.reason               = doc:value(doc:find("payload", "info", "reason"))
        msg.Fields.os                   = doc:value(doc:find("environment", "system", "os", "name"))
        msg.Fields.telemetryEnabled     = doc:value(doc:find("environment", "settings", "telemetryEnabled"))
        msg.Fields.activeExperimentId   = doc:value(doc:find("environment", "addons", "activeExperiment", "id"))
        msg.Fields.clientId             = doc:value(doc:find("clientId"))
        msg.Fields.sourceVersion        = sourceVersion
        msg.Fields.docType              = doc:value(doc:find("type"))

        local app = doc:find("application")
        msg.Fields.appName              = doc:value(doc:find(app, "name"))
        msg.Fields.appVersion           = doc:value(doc:find(app, "version"))
        msg.Fields.appBuildId           = doc:value(doc:find(app, "buildId"))
        msg.Fields.appUpdateChannel     = doc:value(doc:find(app, "channel"))
        msg.Fields.appVendor            = doc:value(doc:find(app, "vendor"))

        remove_objects(msg, doc, "environment", environment_objects)
        remove_objects(msg, doc, "payload", extract_payload_objects[msg.Fields.docType])
        -- /new code
    elseif doc:value(doc:find("deviceinfo")) ~= nil then
        -- Old 'appusage' ping, see Bug 982663
        msg.Fields.docType = "appusage"
        if not validate_schema(hsr, msg, doc, 3) then return false end
        submissionField.value = doc
        msg.Fields.submission = submissionField

        -- Special version for this old format
        msg.Fields.sourceVersion = "3"

        local av = doc:value(doc:find("deviceinfo", "platform_version"))
        local auc = doc:value(doc:find("deviceinfo", "update_channel"))
        local abi = doc:value(doc:find("deviceinfo", "platform_build_id"))

        -- Get some more dimensions.
        msg.Fields.appName = "FirefoxOS"
        msg.Fields.appVersion = av or UNK_DIM
        msg.Fields.appUpdateChannel = auc or UNK_DIM
        msg.Fields.appBuildId = abi or UNK_DIM
        msg.Fields.normalizedChannel = mtn.channel(auc)

        -- The "telemetryEnabled" flag does not apply to this type of ping.
    elseif doc:value(doc:find("v")) then
        -- This is a Fennec "core" ping
        local sourceVersion = doc:value(doc:find("v"))
        if not validate_schema(hsr, msg, doc, sourceVersion) then return false end
        msg.Fields.sourceVersion = tostring(sourceVersion)
        clientId = doc:value(doc:find("clientId"))
        msg.Fields.clientId = clientId
        submissionField.value = doc
        msg.Fields.submission = submissionField
    else
        -- Everything else. Just store the submission in the submission field by default.
        if not validate_schema(hsr, msg, doc, 1) then return false end
        submissionField.value = doc
        msg.Fields.submission = submissionField
    end

    if type(msg.Fields.clientId) == "string" then
        msg.Fields.sampleId = crc32()(msg.Fields.clientId) % 100
    end

    return true
end


function transform_message(hsr)
    if cfg.inject_raw then
        -- duplicate the raw message
        pcall(inject_message, hsr)
    end

    if geoip then
        -- reopen city_db once an hour
        local current_hour = floor(os.time() / 3600)
        if current_hour > hour then
            city_db:close()
            city_db = assert(geoip.open(cfg.city_db_file))
            hour = current_hour
        end
    end
    local msg = process_uri(hsr)
    if msg then
        msg.Type        = "telemetry"
        msg.EnvVersion  = hsr:read_message("EnvVersion")
        msg.Hostname    = hsr:read_message("Hostname")
        -- Note: 'Hostname' is the host name of the server that received the
        -- message, while 'Host' is the name of the HTTP endpoint the client
        -- used (such as "incoming.telemetry.mozilla.org").
        msg.Fields.Host            = hsr:read_message("Fields[Host]")
        msg.Fields.DNT             = hsr:read_message("Fields[DNT]")
        msg.Fields.Date            = hsr:read_message("Fields[Date]")
        msg.Fields.submissionDate  = os.date("%Y%m%d", msg.Timestamp / 1e9)
        msg.Fields.sourceName      = "telemetry"
        msg.Fields["X-PingSender-Version"] = hsr:read_message("Fields[X-PingSender-Version]")

        if process_json(hsr, msg) then
            local ok, err = pcall(inject_message, msg)
            if not ok then
                -- Note: we do NOT pass the extra message fields here,
                -- since it's likely that would simply hit the same
                -- error when injecting.
                inject_error(hsr, "inject_message", err)
            end
        end
    end
end

function decode(msg)
    hsr:decode_message(msg)
    transform_message(hsr)
end

return M
