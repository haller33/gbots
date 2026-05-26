-- bot_nars_pipe.lua – Galcon bot using NARS via input.nal / derived.nal
-- NO FALLBACK – only executes NARS operations
-- Now sends best_target fact computed by classic formula
-- Usage: gbots pipe -name nars_bot -exec 'lua bot_nars_pipe.lua'
-- Before starting, run: ./daemon_reason.sh start

local input_file = "/home/synbian/git/clone/NARS/SemanticGraphSearch/input.nal"
local derived_file = "/home/synbian/git/clone/NARS/SemanticGraphSearch/derived.nal"

local SLEEP_NARS_THINK=5.0

-- Helper: cross‑platform sleep
local function sleep(seconds)
    if socket.sleep then
        socket.sleep(seconds)
    else
        os.execute("sleep " .. seconds)
    end
end

function send(msg)
    io.stdout:write(msg .. "\n")
    io.stdout:flush()
end

function log(line)
    io.stderr:write(line .. "\n")
    io.stderr:flush()
end

-- Append a line to input.nal
function write_to_nars(line)
    local f = io.open(input_file, "a")
    if f then
        f:write(line .. "\n")
        f:flush()
        f:close()
    end
end

-- Read all lines from derived.nal that start with '^'
function read_nars_operations()
    local ops = {}
    local f = io.open(derived_file, "r")
    if not f then return ops end
    for line in f:lines() do
        if line:match("^%^") then
            local send_cmd = line:match("^%^send%((%d+),(%d+),(%d+)%)")
            if send_cmd then
                table.insert(ops, {cmd="SEND", src=tonumber(send_cmd), 
                                   tgt=tonumber(select(2, send_cmd)), 
                                   pct=tonumber((select(3, send_cmd)))})
            else
                local redir_cmd = line:match("^%^redirect%((%d+),(%d+)%)")
                if redir_cmd then
                    table.insert(ops, {cmd="REDIR", src=tonumber(redir_cmd), 
                                       tgt=tonumber(select(2, redir_cmd))})
                end
            end
        end
    end
    f:close()
    return ops
end

-- Clear derived.nal after reading (to avoid reprocessing)
function clear_derived()
    local f = io.open(derived_file, "w")
    if f then f:close() end
end

-----------------------------------------------------------------------
-- Team & geometry helpers
-----------------------------------------------------------------------
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

-- Classic target value: -ships + production - distance*0.20
function target_value(g, target_id, from_id, user_team)
    local target = g.items[target_id]
    if not target or target.type ~= "planet" then return -1e9 end
    local target_team = get_team(g, target_id)
    if target_team == user_team then return -1e9 end
    local dist = distance_between(g, from_id, target_id)
    return -target.ships + target.production - dist * 0.20
end

-- Find the best target for the classic bot (uses from_planet to compute distance)
function find_best_target(g, user_id, from_id)
    local user_team = get_team(g, user_id)
    local best_id = 0
    local best_val = -1e9
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local val = target_value(g, obj.n, from_id, user_team)
            if val > best_val then
                best_val = val
                best_id = obj.n
            end
        end
    end
    return best_id
end

-- Find the strongest source planet (with >= 17 ships)
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

-----------------------------------------------------------------------
-- NARS state encoding (with angle brackets) and best_target injection
-----------------------------------------------------------------------
function send_state_to_nars(g)
    local lines = {}
    -- Basic facts with angle brackets
    table.insert(lines, "<step>. :|:")
    local my_team = get_team(g, g.you)
    table.insert(lines, string.format("<player(%d)>. :|:", g.you))
    table.insert(lines, string.format("<team(%d)>. :|:", my_team))

    -- Planets
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local owner_team = get_team(g, obj.owner)
            table.insert(lines, string.format("<planet_ships(%d,%f)>. :|:", obj.n, obj.ships))
            table.insert(lines, string.format("<planet_prod(%d,%f)>. :|:", obj.n, obj.production))
            if obj.owner == g.you then
                table.insert(lines, string.format("<my_planet(%d)>. :|:", obj.n))
            elseif owner_team ~= 0 then
                table.insert(lines, string.format("<enemy_planet(%d)>. :|:", obj.n))
            else
                table.insert(lines, string.format("<neutral_planet(%d)>. :|:", obj.n))
            end
        end
    end

    -- Fleets (optional, currently not used by rules)
    for _, obj in pairs(g.items) do
        if obj.type == "fleet" and obj.owner == g.you then
            table.insert(lines, string.format("<fleet_source(%d,%d)>. :|:", obj.n, obj.source))
            table.insert(lines, string.format("<fleet_target(%d,%d)>. :|:", obj.n, obj.target))
        end
    end

    if is_winning(g, my_team) then
        table.insert(lines, "<winning>. :|:")
    end

    -- 2. Compute best target using classic formula (from the strongest source)
    local source = find_attack_source(g, g.you)
    if source ~= 0 then
        local best_target = find_best_target(g, g.you, source)
        if best_target ~= 0 then
            table.insert(lines, string.format("<best_target(%d)>. :|:", best_target))
            log("Classic bot: best_target = " .. best_target)
        end
    end

    -- Write all lines to input.nal
    for _, line in ipairs(lines) do
        write_to_nars(line)
    end
end

-----------------------------------------------------------------------
-- Bot decision: ONLY use NARS operations, no fallback
-----------------------------------------------------------------------
function bot(g)
    -- 1. Send current state to NARS (with angle brackets and best_target)
    send_state_to_nars(g)

    -- 2. Give NARS a moment to process (50 ms sleep)
    sleep(SLEEP_NARS_THINK)
    
    -- 3. Read operations from derived.nal
    local ops = read_nars_operations()
    if #ops > 0 then
        for _, op in ipairs(ops) do
            if op.cmd == "SEND" then
                send(string.format("/SEND %d %d %d", op.pct, op.src, op.tgt))
                log("NARS: /SEND " .. op.pct .. " " .. op.src .. " " .. op.tgt)
            elseif op.cmd == "REDIR" then
                send(string.format("/REDIR %d %d", op.src, op.tgt))
                log("NARS: /REDIR " .. op.src .. " " .. op.tgt)
            end
        end
        -- Clear derived.nal to avoid re-executing the same operations
        -- clear_derived()
    else
        -- No fallback: do nothing (just log)
        log("NARS: no operations received, doing nothing")
    end
end

-----------------------------------------------------------------------
-- Protocol parser (unchanged from original)
-----------------------------------------------------------------------
function split(str, delim)
    local r = {}
    for k in (str..delim):gmatch("([^"..delim.."]*)"..delim) do
        r[#r+1] = k
    end
    return r
end

function join(t, delim) return table.concat(t, delim) end

function slice(t, a, b)
    local r = {}
    for i = a, b do r[i-a+1] = t[i] end
    return r
end

function toint(v) return math.floor(tonumber(v)) end

function parse(g, line)
    local t = split(line, '\t')
    if t[1]:sub(1,1) ~= '/' then return sync(g, t) end
    if t[1] == "/TICK" then
        bot(g)
        send("/TOCK")
    elseif t[1] == "/PRINT" then
        log(join(slice(t,2,#t), '\t'))
    elseif t[1] == "/RESULTS" then
        log(join(slice(t,2,#t), '\t'))
    elseif t[1] == "/RESET" then
        for k, v in pairs(g) do g[k] = nil end
        g.you = 0; g.state = ''; g.items = {}
    elseif t[1] == "/SET" then
        if t[2] == "YOU" then g.you = toint(t[3])
        elseif t[2] == "STATE" then g.state = t[3] end
    elseif t[1] == "/USER" then
        local n = toint(t[2])
        g.items[n] = {
            n = n,
            type = "user",
            name = t[3],
            color = tonumber(t[4], 16),
            team = toint(t[5]),
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
            radius = tonumber(t[8]),
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
            radius = tonumber(t[9]),
        }
    elseif t[1] == "/DESTROY" then
        local n = toint(t[2])
        g.items[n] = nil
    elseif t[1] == "/ERROR" then
        log(join(slice(t,2,#t), '\t'))
    else
        log("unhandled command: " .. join(t, '\t'))
    end
end

function sync(g, t)
    local nFields, fields = #t[1], t[1]:upper()
    local i = 2
    while i <= #t do
        local n = toint(t[i])
        i = i + 1
        local o = g.items[n]
        if o ~= nil then
            for j = 1, nFields do
                local v = t[i]
                i = i + 1
                local f = fields:sub(j, j)
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
    -- Clear input.nal and derived.nal at start
    local f = io.open(input_file, "w"); if f then f:close() end
    f = io.open(derived_file, "w"); if f then f:close() end

    local g = { you = 0, state = '', items = {} }
    while true do
        local line = io.stdin:read()
        if line == nil then break end
        if #line > 0 then
            parse(g, line)
        end
    end
end

main()
