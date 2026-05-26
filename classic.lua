-- bot.lua -- classic bot AI for Galcon
-- Based on the Go classic bot implementation

function send(msg) io.stdout:write(msg..'\n') ; io.stdout:flush() end
function log(line) io.stderr:write(line .. '\n') ; io.stderr:flush() end

--------------------------------------------------------------------------------
-- Helper functions for the classic bot

function get_team(g, id)
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

function distance_between(g, id1, id2)
    local a = g.items[id1]
    local b = g.items[id2]
    if not a or not b then return 99999 end
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx*dx + dy*dy)
end

function count_ships_by_team(g)
    local counts = {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" or obj.type == "fleet" then
            local team = get_team(g, obj.owner or 0)
            counts[team] = (counts[team] or 0) + obj.ships
        end
    end
    return counts
end

function is_winning(g, team)
    local ships = count_ships_by_team(g)
    local my_ships = ships[team] or 0
    local enemy_ships = 0
    for t, s in pairs(ships) do
        if t ~= 0 and t ~= team then
            enemy_ships = enemy_ships + s
        end
    end
    return my_ships > enemy_ships * 2
end

-- value = -ships + production - distance*0.20
-- if winning_mode == true, skip neutral planets (team 0)
function target_value(g, target_id, from_id, winning_mode, user_team)
    local target = g.items[target_id]
    if not target or target.type ~= "planet" then return -1e9 end
    local target_team = get_team(g, target_id)
    if target_team == user_team then return -1e9 end
    if winning_mode and target_team == 0 then return -1e9 end

    local dist = distance_between(g, from_id, target_id)
    return -target.ships + target.production - dist * 0.20
end

function find_best_target(g, user_id, from_id, winning_mode)
    local user_team = get_team(g, user_id)
    local best_id = 0
    local best_val = -1e9
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local val = target_value(g, obj.n, from_id, winning_mode, user_team)
            if val > best_val then
                best_val = val
                best_id = obj.n
            end
        end
    end
    return best_id
end

function find_attack_source(g, user_id)
    local best_id = 0
    local best_ships = 0
    for _, obj in pairs(g.items) do
        if obj.type == "planet" and obj.owner == user_id then
            if obj.ships >= 17 and obj.ships > best_ships then
                best_ships = obj.ships
                best_id = obj.n
            end
        end
    end
    return best_id
end

function redirect_fleets(g, user_id, winning)
    for _, fleet in pairs(g.items) do
        if fleet.type == "fleet" and fleet.owner == user_id then
            local new_target = find_best_target(g, user_id, fleet.n, winning)
            if new_target ~= 0 and new_target ~= fleet.target then
                send(string.format("/REDIR %d %d", fleet.source, new_target))
            end
        end
    end
end

--------------------------------------------------------------------------------
-- The bot's main decision function (called every /TICK)

function bot(g)
    -- build list of all planets and my planets (not strictly needed, but used for old random code)
    local all_planets, my_planets = {}, {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            all_planets[#all_planets+1] = obj
            if obj.owner == g.you then
                my_planets[#my_planets+1] = obj
            end
        end
    end
    if #all_planets == 0 or #my_planets == 0 then return end

    local user_team = get_team(g, g.you)
    local winning = is_winning(g, user_team)

    -- 1. choose source planet
    local source_id = find_attack_source(g, g.you)
    if source_id ~= 0 then
        -- 2. choose target
        local target_id = find_best_target(g, g.you, source_id, winning)
        if target_id ~= 0 then
            -- 3. send 65% of ships
            send(string.format("/SEND %d %d %d", 65, source_id, target_id))
        end
    end

    -- 4. redirect existing fleets to better targets
    redirect_fleets(g, g.you, winning)
end

--------------------------------------------------------------------------------
-- Protocol parser (unchanged from original, kept for completeness)

function split(str,delim)
    local r = {}
    for k in (str..delim):gmatch("([^"..delim.."]*)"..delim) do
        r[#r+1] = k
    end
    return r
end
function join(t,delim) return table.concat(t,delim) end
function slice(t,a,b)
    local r = {}
    for i=a,b do r[i-a+1] = t[i] end
    return r
end
function toint(v) return math.floor(tonumber(v)) end

function parse(g,line)
    local t = split(line,'\t')
    if t[1]:sub(1,1) ~= '/' then return sync(g,t) end
    if t[1] == "/TICK" then
        bot(g)
        send("/TOCK")
    elseif t[1] == "/PRINT" then
        log(join(slice(t,2,#t),'\t'))
    elseif t[1] == "/RESULTS" then
        log(join(slice(t,2,#t),'\t'))
    elseif t[1] == "/RESET" then
        for k,v in pairs(g) do g[k] = nil end
        g.you = 0; g.state=''; g.items={}
    elseif t[1] == "/SET" then
        if t[2] == "YOU" then g.you = toint(t[3])
        elseif t[2] == "STATE" then g.state = t[3] end
    elseif t[1] == "/USER" then
        local n = toint(t[2])
        g.items[n] = {
            n=     n,
            type=  "user",
            name=  t[3],
            color= tonumber(t[4],16),
            team=  toint(t[5]),
        }
    elseif t[1] == "/PLANET" then
        local n = toint(t[2])
        g.items[n] = {
            n=          n,
            type=       "planet",
            owner=      toint(t[3]),
            ships=      tonumber(t[4]),
            x=          tonumber(t[5]),
            y=          tonumber(t[6]),
            production= tonumber(t[7]),
            radius=     tonumber(t[8]),
        }
    elseif t[1] == "/FLEET" then
        local n = toint(t[2])
        g.items[n] = {
            n=      n,
            type=   "fleet",
            owner=  toint(t[3]),
            ships=  tonumber(t[4]),
            x=      tonumber(t[5]),
            y=      tonumber(t[6]),
            source= toint(t[7]),
            target= toint(t[8]),
            radius= tonumber(t[9]),
        }
    elseif t[1] == "/DESTROY" then
        local n = toint(t[2])
        g.items[n] = nil
    elseif t[1] == "/ERROR" then
        log(join(slice(t,2,#t),'\t'))
    else
        log("unhandled command: " .. join(t,'\t'))
    end
end

function sync(g,t)
    local nFields, fields = #t[1], t[1]:upper()
    local i = 2
    while i <= #t do
        local n = toint(t[i])
        i = i + 1
        local o = g.items[n]
        if o ~= nil then
            for j=1,nFields do
                local v = t[i]
                i = i + 1
                local f = fields:sub(j,j)
                if f == 'X' then o.x = tonumber(v)
                elseif f == 'Y' then o.y = tonumber(v)
                elseif f == 'S' then o.ships = tonumber(v)
                elseif f == 'R' then o.radius = tonumber(v)
                elseif f == 'O' then o.owner = toint(v)
                elseif f == 'T' then o.target = toint(v)
                end
            end
        else
            i = i + nFields
        end
    end
end

function main()
    local g = {you=0,state='',items={}}
    while true do
        local line = io.stdin:read()
        if line == nil then break end
        if #line > 0 then
            parse(g, line)
        end
    end
end

main()
