-- galcon.lua
-- Shared library for Galcon bots (Lua)
-- Provides protocol parsing, game state helpers, logging, and a main loop.

local galcon = {}

-- ----------------------------------------------------------------------
-- Logging (stderr)
-- ----------------------------------------------------------------------
function galcon.log(...)
    local args = {...}
    local msg = table.concat(args, " ")
    io.stderr:write(msg .. "\n")
    io.stderr:flush()
end

-- ----------------------------------------------------------------------
-- Game state helpers
-- ----------------------------------------------------------------------

-- Get team ID of a game object (user, planet, fleet)
function galcon.get_team(g, id)
    local obj = g.items[id]
    if not obj then return 0 end
    if obj.type == "user" then
        return obj.team or 0
    elseif obj.type == "planet" or obj.type == "fleet" then
        if obj.owner and obj.owner ~= 0 then
            return galcon.get_team(g, obj.owner)
        end
    end
    return 0
end

-- Euclidean distance between two objects (by ID)
function galcon.distance_between(g, id1, id2)
    local a = g.items[id1]
    local b = g.items[id2]
    if not a or not b or not a.x or not a.y or not b.x or not b.y then
        return 99999
    end
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx*dx + dy*dy)
end

-- Count total ships per team (planets + fleets)
function galcon.count_ships_by_team(g)
    local counts = {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" or obj.type == "fleet" then
            local team = galcon.get_team(g, obj.owner or 0)
            counts[team] = (counts[team] or 0) + obj.ships
        end
    end
    return counts
end

-- Check if given team is winning (my_ships > 2 * enemy_ships)
function galcon.is_winning(g, team)
    local ships = galcon.count_ships_by_team(g)
    local my_ships = ships[team] or 0
    local enemy_ships = 0
    for t, s in pairs(ships) do
        if t ~= 0 and t ~= team then
            enemy_ships = enemy_ships + s
        end
    end
    return my_ships > enemy_ships * 2
end

-- Total ships of the user's team
function galcon.total_my_ships(g, user_id)
    return galcon.count_ships_by_team(g)[galcon.get_team(g, user_id)] or 0
end

-- Total ships of all enemy teams combined
function galcon.total_enemy_ships(g, user_id)
    local my_team = galcon.get_team(g, user_id)
    local enemy = 0
    for team, s in pairs(galcon.count_ships_by_team(g)) do
        if team ~= 0 and team ~= my_team then
            enemy = enemy + s
        end
    end
    return enemy
end

-- List of planets owned by the user
function galcon.get_my_planets(g, user_id)
    local planets = {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" and obj.owner == user_id then
            table.insert(planets, obj)
        end
    end
    return planets
end

-- List of planets owned by enemies (team != 0 and != my_team)
function galcon.get_enemy_planets(g, user_id)
    local my_team = galcon.get_team(g, user_id)
    local enemies = {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local team = galcon.get_team(g, obj.owner)
            if team ~= 0 and team ~= my_team then
                table.insert(enemies, obj)
            end
        end
    end
    return enemies
end

-- Strongest planet owned by user (by ship count)
function galcon.get_strongest_planet(g, user_id)
    local best = nil
    for _, p in ipairs(galcon.get_my_planets(g, user_id)) do
        if not best or p.ships > best.ships then best = p end
    end
    return best
end

-- Weakest enemy planet (by ship count)
function galcon.get_weakest_enemy(g, user_id)
    local weakest = nil
    for _, e in ipairs(galcon.get_enemy_planets(g, user_id)) do
        if not weakest or e.ships < weakest.ships then weakest = e end
    end
    return weakest
end

-- Nearest enemy planet to a given planet (by ID)
function galcon.get_nearest_enemy(g, user_id, from_planet_id)
    local from = g.items[from_planet_id]
    if not from then return nil end
    local nearest = nil
    local min_dist = 1e9
    for _, e in ipairs(galcon.get_enemy_planets(g, user_id)) do
        local dist = galcon.distance_between(g, from_planet_id, e.n)
        if dist < min_dist then
            min_dist = dist
            nearest = e
        end
    end
    return nearest
end

-- Strongest enemy planet (by ship count)
function galcon.get_strongest_enemy_planet(g, user_id)
    local my_team = galcon.get_team(g, user_id)
    local strongest = nil
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local team = galcon.get_team(g, obj.owner)
            if team ~= 0 and team ~= my_team then
                if not strongest or obj.ships > strongest.ships then
                    strongest = obj
                end
            end
        end
    end
    return strongest
end

-- Total production per team (sum of planet.production)
function galcon.total_production_by_team(g)
    local prod = {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local team = galcon.get_team(g, obj.owner)
            prod[team] = (prod[team] or 0) + obj.production
        end
    end
    return prod
end

-- ----------------------------------------------------------------------
-- Protocol parsing utilities
-- ----------------------------------------------------------------------

function galcon.split(str, delim)
    local r = {}
    for k in (str..delim):gmatch("([^"..delim.."]*)"..delim) do
        r[#r+1] = k
    end
    return r
end

function galcon.join(t, delim)
    return table.concat(t, delim)
end

function galcon.slice(t, a, b)
    local r = {}
    for i = a, b do
        r[i-a+1] = t[i]
    end
    return r
end

function galcon.toint(v)
    return math.floor(tonumber(v))
end

-- ----------------------------------------------------------------------
-- State update: sync differential updates (FIELDS lines)
-- ----------------------------------------------------------------------
function galcon.sync(g, t)
    local nFields, fields = #t[1], t[1]:upper()
    local i = 2
    while i <= #t do
        local n = galcon.toint(t[i])
        i = i + 1
        local o = g.items[n]
        if o then
            for j = 1, nFields do
                local v = t[i]
                i = i + 1
                local f = fields:sub(j, j)
                if f == 'X' then o.x = tonumber(v)
                elseif f == 'Y' then o.y = tonumber(v)
                elseif f == 'S' then o.ships = tonumber(v)
                elseif f == 'R' then o.radius = tonumber(v)
                elseif f == 'O' then o.owner = galcon.toint(v)
                elseif f == 'T' then o.target = galcon.toint(v)
                end
            end
        else
            i = i + nFields
        end
    end
end

-- ----------------------------------------------------------------------
-- Main protocol parser
-- Calls user's bot function on /TICK.
-- ----------------------------------------------------------------------
function galcon.parse(g, line, bot_func)
    local t = galcon.split(line, '\t')
    if t[1]:sub(1,1) ~= '/' then
        galcon.sync(g, t)
        return
    end

    if t[1] == "/TICK" then
        if bot_func then
            bot_func(g)
        end
        io.stdout:write("/TOCK\n")
        io.stdout:flush()
    elseif t[1] == "/PRINT" or t[1] == "/RESULTS" then
        galcon.log(galcon.join(galcon.slice(t, 2, #t), '\t'))
    elseif t[1] == "/RESET" then
        -- Clear game state
        for k, v in pairs(g) do g[k] = nil end
        g.you = 0
        g.state = ''
        g.items = {}
    elseif t[1] == "/SET" then
        if t[2] == "YOU" then
            g.you = galcon.toint(t[3])
        elseif t[2] == "STATE" then
            g.state = t[3]
        end
    elseif t[1] == "/USER" then
        local n = galcon.toint(t[2])
        g.items[n] = {
            n = n,
            type = "user",
            name = t[3],
            color = tonumber(t[4], 16),
            team = galcon.toint(t[5]),
        }
    elseif t[1] == "/PLANET" then
        local n = galcon.toint(t[2])
        g.items[n] = {
            n = n,
            type = "planet",
            owner = galcon.toint(t[3]),
            ships = tonumber(t[4]),
            x = tonumber(t[5]),
            y = tonumber(t[6]),
            production = tonumber(t[7]),
            radius = tonumber(t[8]),
        }
    elseif t[1] == "/FLEET" then
        local n = galcon.toint(t[2])
        g.items[n] = {
            n = n,
            type = "fleet",
            owner = galcon.toint(t[3]),
            ships = tonumber(t[4]),
            x = tonumber(t[5]),
            y = tonumber(t[6]),
            source = galcon.toint(t[7]),
            target = galcon.toint(t[8]),
            radius = tonumber(t[9]),
        }
    elseif t[1] == "/DESTROY" then
        local n = galcon.toint(t[2])
        g.items[n] = nil
    elseif t[1] == "/ERROR" then
        galcon.log(galcon.join(galcon.slice(t, 2, #t), '\t'))
    else
        galcon.log("unhandled: " .. galcon.join(t, '\t'))
    end
end

-- ----------------------------------------------------------------------
-- Main loop: reads stdin, calls parse with user's bot function.
-- ----------------------------------------------------------------------
function galcon.run(bot_func)
    local g = { you = 0, state = '', items = {} }
    while true do
        local line = io.stdin:read()
        if not line then break end
        if #line > 0 then
            galcon.parse(g, line, bot_func)
        end
    end
end

-- ----------------------------------------------------------------------
-- Convenience: send a raw command to Galcon (stdout)
-- ----------------------------------------------------------------------
function galcon.send(cmd)
    io.stdout:write(cmd .. "\n")
    io.stdout:flush()
end

return galcon
