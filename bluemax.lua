#!/usr/bin/env lua
-- bluemax.lua – standalone Lua port of ExaltedToast's Bluemax bot
-- Fixed: state handling, team-based enemy detection, production safety
-- # current original python code was shared to my by ExaltedToast

-- Constants (exactly as in Python)
local SEND_PROP = 0.425
local DELTA_PROP = 0.300
local HOLD_PROP = 0.200

-- ----------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------
local function send(msg)
    io.stdout:write(msg .. "\n")
    io.stdout:flush()
end

local function log(msg)
    io.stderr:write(msg .. "\n")
    io.stderr:flush()
end

local function round(x)
    return math.floor(x + 0.5)
end

-- ----------------------------------------------------------------------
-- Team resolution (to match gbotlib.categorize)
-- ----------------------------------------------------------------------
local function get_team(g, id)
    local obj = g.items[id]
    if not obj then return 0 end
    if obj.type == "user" then
        return obj.team or 0
    elseif obj.type == "planet" or obj.type == "fleet" then
        if obj.owner and obj.owner ~= 0 then
            return get_team(g, obj.owner)
        end
    end
    return 0
end

-- Get bot's team ID
local function my_team(g)
    return get_team(g, g.you)
end

-- ----------------------------------------------------------------------
-- Planet classification (by TEAM, not owner ID)
-- ----------------------------------------------------------------------
local function get_my_planets(g)
    local my_t = my_team(g)
    local planets = {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local owner_team = get_team(g, obj.owner)
            if owner_team == my_t and owner_team ~= 0 then
                table.insert(planets, obj)
            end
        end
    end
    return planets
end

-- Planets whose team is different from bot's team (enemies + neutrals)
local function get_enemy_planets(g)
    local my_t = my_team(g)
    local enemies = {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local owner_team = get_team(g, obj.owner)
            if owner_team ~= my_t then
                table.insert(enemies, obj)
            end
        end
    end
    return enemies
end

-- ----------------------------------------------------------------------
-- Bluemax bot decision (no state check – acts on every tick, like classic.lua)
-- ----------------------------------------------------------------------
local function bot(g)
    -- REMOVED strict state check: classic.lua works without it.
    -- If you want to keep it, uncomment and ensure g.state is exactly "play".
    -- if g.state ~= "play" then return end

    local my_planets = get_my_planets(g)
    local targets = get_enemy_planets(g)

    if #targets == 0 then
        return
    end

    -- Sort by production/(ships+1) descending (best targets first)
    table.sort(targets, function(a, b)
        local va = a.production / (a.ships + 1)
        local vb = b.production / (b.ships + 1)
        return va > vb
    end)

    for _, planet in ipairs(my_planets) do
        local ships = planet.ships
        local idx = 0
        local num_targets = #targets

        -- Ensure production is a positive number; if missing or zero, treat as 1
        local prod = (planet.production and planet.production > 0) and planet.production or 1

        while ships >= HOLD_PROP * prod do
            local target = targets[(idx % num_targets) + 1]
            local percent = round(SEND_PROP * 100)
            send(string.format("/SEND %d %d %d", percent, planet.n, target.n))
            idx = idx + 1
            ships = ships * DELTA_PROP
        end
    end
end

-- ----------------------------------------------------------------------
-- Galcon protocol parser (complete, self‑contained)
-- ----------------------------------------------------------------------
local function split(str, delim)
    local r = {}
    for k in (str .. delim):gmatch("([^" .. delim .. "]*)" .. delim) do
        r[#r + 1] = k
    end
    return r
end

local function join(t, delim)
    return table.concat(t, delim)
end

local function slice(t, a, b)
    local r = {}
    for i = a, b do
        r[i - a + 1] = t[i]
    end
    return r
end

local function toint(v)
    return math.floor(tonumber(v))
end

local function sync(g, t)
    local nFields = #t[1]
    local fields = t[1]:upper()
    local i = 2
    while i <= #t do
        local n = toint(t[i])
        i = i + 1
        local o = g.items[n]
        if o then
            for j = 1, nFields do
                local v = t[i]
                i = i + 1
                local f = fields:sub(j, j)
                if f == 'X' then
                    o.x = tonumber(v)
                elseif f == 'Y' then
                    o.y = tonumber(v)
                elseif f == 'S' then
                    o.ships = tonumber(v)
                elseif f == 'R' then
                    o.radius = tonumber(v)
                elseif f == 'O' then
                    o.owner = toint(v)
                elseif f == 'T' then
                    o.target = toint(v)
                end
            end
        else
            i = i + nFields
        end
    end
end

local function parse(g, line)
    local t = split(line, '\t')
    if t[1]:sub(1, 1) ~= '/' then
        sync(g, t)
        return
    end

    if t[1] == "/TICK" then
        bot(g)
        send("/TOCK")
    elseif t[1] == "/PRINT" or t[1] == "/RESULTS" then
        log(join(slice(t, 2, #t), '\t'))
    elseif t[1] == "/RESET" then
        for k, v in pairs(g) do
            g[k] = nil
        end
        g.you = 0
        g.state = ''
        g.items = {}
    elseif t[1] == "/SET" then
        if t[2] == "YOU" then
            g.you = toint(t[3])
        elseif t[2] == "STATE" then
            g.state = t[3]
        end
    elseif t[1] == "/USER" then
        local n = toint(t[2])
        g.items[n] = {
            n = n,
            type = "user",
            name = t[3],
            color = tonumber(t[4], 16),
            team = toint(t[5])
        }
    elseif t[1] == "/PLANET" then
        local n = toint(t[2])
        g.items[n] = {
            n = n,
            type = "planet",
            owner = toint(t[3]),
            ships = tonumber(t[4]),
            x = tonumber(t[5]),
            y = tonumber(t[6]),
            production = tonumber(t[7]),
            radius = tonumber(t[8])
        }
    elseif t[1] == "/FLEET" then
        local n = toint(t[2])
        g.items[n] = {
            n = n,
            type = "fleet",
            owner = toint(t[3]),
            ships = tonumber(t[4]),
            x = tonumber(t[5]),
            y = tonumber(t[6]),
            source = toint(t[7]),
            target = toint(t[8]),
            radius = tonumber(t[9])
        }
    elseif t[1] == "/DESTROY" then
        local n = toint(t[2])
        g.items[n] = nil
    elseif t[1] == "/ERROR" then
        log(join(slice(t, 2, #t), '\t'))
    else
        log("unhandled: " .. join(t, '\t'))
    end
end

-- ----------------------------------------------------------------------
-- Main loop
-- ----------------------------------------------------------------------
local function main()
    local g = { you = 0, state = '', items = {} }
    while true do
        local line = io.stdin:read()
        if not line then
            break
        end
        if #line > 0 then
            parse(g, line)
        end
    end
end

main()
