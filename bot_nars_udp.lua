-- bot_nars_udp.lua – Galcon bot using UDPNAR, loads rules from file
-- Usage: gbots pipe -name nars_bot -exec 'lua bot_nars_udp.lua'
-- Before starting, run: ./NAR UDPNAR 127.0.0.1 50000 10000000 true

local socket = require("socket")

-- Configuration
local UDP_IP = "127.0.0.1"
local UDP_PORT = 50000
local RULES_FILE = "classic_bot_rules.nal"
local SLEEP_TIME = 0.01
local SLEEP_NARS_THINK = 5.00

local udp = socket.udp()
udp:settimeout(0.01)
udp:setpeername(UDP_IP, UDP_PORT)

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

-- Load rules file and send each line (non‑empty, not a comment) to UDPNAR
function load_rules()
    local f = io.open(RULES_FILE, "r")
    if not f then
        log("WARNING: Could not open " .. RULES_FILE .. " – no rules loaded")
        return
    end
    for line in f:lines() do
        -- Skip empty lines and comments (//)
        if line:match("^%s*//") or line:match("^%s*$") then
            -- comment or empty, ignore
        else
            -- Remove trailing whitespace
            line = line:gsub("%s+$", "")
            if #line > 0 then
                udp:send(line .. "\n")
                log("Loaded rule: " .. line)
                -- Give NARS a moment to process each rule
                sleep(SLEEP_TIME)
            end
        end
    end
    f:close()
    log("Rules loaded.")
end

-----------------------------------------------------------------------
-- Team & geometry helpers (same as before)
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

function target_value(g, target_id, from_id, user_team, winning_mode)
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
            local val = target_value(g, obj.n, from_id, user_team, winning_mode)
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

-----------------------------------------------------------------------
-- Build atomic Narsese state
-----------------------------------------------------------------------
function build_narsese_old(g)
    local lines = {}
    lines[#lines+1] = "step. :|:"
    local my_team = get_team(g, g.you)
    lines[#lines+1] = string.format("player_%d. :|:", g.you)
    lines[#lines+1] = string.format("team_%d. :|:", my_team)

    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local owner_team = get_team(g, obj.owner)
            lines[#lines+1] = string.format("planet_ships_%d_%d. :|:", obj.n, math.floor(obj.ships))
            lines[#lines+1] = string.format("planet_prod_%d_%d. :|:", obj.n, math.floor(obj.production))
            if obj.owner == g.you then
                lines[#lines+1] = string.format("planet_%d_my. :|:", obj.n)
            elseif owner_team ~= 0 then
                lines[#lines+1] = string.format("planet_%d_enemy. :|:", obj.n)
            else
                lines[#lines+1] = string.format("planet_%d_neutral. :|:", obj.n)
            end
        end
    end

    if is_winning(g, my_team) then
        lines[#lines+1] = "winning. :|:"
    end

    -- Classic bot decision: compute best source and target
    local source = find_attack_source(g, g.you)
    if source ~= 0 then
        local winning = is_winning(g, my_team)
        local target = find_best_target(g, g.you, source, winning)
        if target ~= 0 then
            lines[#lines+1] = string.format("source_%d. :|:", source)
            lines[#lines+1] = string.format("target_%d. :|:", target)
            log("Classic: source=" .. source .. " target=" .. target)
        end
    end

    return lines
end

function send_state_to_udp_old(g)
    local lines = build_narsese(g)
    for _, line in ipairs(lines) do
        udp:send(line .. "\n")
    end
end

function parse_udp_operations_old(data)
    local ops = {}
    for line in data:gmatch("[^\r\n]+") do
        if line:match("^%^send%(") then
            local src, tgt, pct = line:match("^%^send%((%d+),(%d+),(%d+)%)")
            if src and tgt and pct then
                table.insert(ops, {cmd="SEND", src=tonumber(src), tgt=tonumber(tgt), pct=tonumber(pct)})
            end
        elseif line:match("^%^redirect%(") then
            local src, tgt = line:match("^%^redirect%((%d+),(%d+)%)")
            if src and tgt then
                table.insert(ops, {cmd="REDIR", src=tonumber(src), tgt=tonumber(tgt)})
            end
        end
    end
    return ops
end
-----------------------------------------------------------------------
-- Build Narsese state (with angle brackets)
-----------------------------------------------------------------------
function build_narsese(g)
    local lines = {}
    table.insert(lines, "<step>. :|:")
    local my_team = get_team(g, g.you)
    table.insert(lines, string.format("<player(%d)>. :|:", g.you))
    table.insert(lines, string.format("<team(%d)>. :|:", my_team))

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

    for _, obj in pairs(g.items) do
        if obj.type == "fleet" and obj.owner == g.you then
            table.insert(lines, string.format("<fleet_source(%d,%d)>. :|:", obj.n, obj.source))
            table.insert(lines, string.format("<fleet_target(%d,%d)>. :|:", obj.n, obj.target))
        end
    end

    if is_winning(g, my_team) then
        table.insert(lines, "<winning>. :|:")
    end

    -- Hybrid: inject best_target computed by classic bot
    local source = find_attack_source(g, g.you)
    if source ~= 0 then
        local winning = is_winning(g, my_team)
        local best_target = find_best_target(g, g.you, source, winning)
        if best_target ~= 0 then
            table.insert(lines, string.format("<best_target(%d)>. :|:", best_target))
        end
    end

    return lines
end

function send_state_to_udp(g)
    local lines = build_narsese(g)
    for _, line in ipairs(lines) do
        udp:send(line .. "\n")
    end
end

function parse_udp_operations(data)
    local ops = {}
    for line in data:gmatch("[^\r\n]+") do
        if line:match("^%^send%(") then
            local src, tgt, pct = line:match("^%^send%((%d+),(%d+),(%d+)%)")
            if src and tgt and pct then
                table.insert(ops, {cmd="SEND", src=tonumber(src), tgt=tonumber(tgt), pct=tonumber(pct)})
            end
        elseif line:match("^%^redirect%(") then
            local src, tgt = line:match("^%^redirect%((%d+),(%d+)%)")
            if src and tgt then
                table.insert(ops, {cmd="REDIR", src=tonumber(src), tgt=tonumber(tgt)})
            end
        end
    end
    return ops
end

-----------------------------------------------------------------------
-- Main bot decision (called every /TICK)
-----------------------------------------------------------------------
function bot(g)
    -- Send state to UDPNAR
    send_state_to_udp(g)

    -- Give NARS time to think (50 ms)
    sleep(SLEEP_NARS_THINK)

    -- Receive operations
    local ops = {}
    while true do
        local data, err = udp:receive()
        if not data then break end
        local new_ops = parse_udp_operations(data)
        for _, op in ipairs(new_ops) do
            table.insert(ops, op)
        end
    end

    if #ops > 0 then
        for _, op in ipairs(ops) do
            if op.cmd == "SEND" then
                send(string.format("/SEND %d %d %d", op.pct, op.src, op.tgt))
                log("UDPNARS: /SEND " .. op.pct .. " " .. op.src .. " " .. op.tgt)
            elseif op.cmd == "REDIR" then
                send(string.format("/REDIR %d %d", op.src, op.tgt))
                log("UDPNARS: /REDIR " .. op.src .. " " .. op.tgt)
            end
        end
    else
        log("UDPNARS: no operations received")
    end
end

-----------------------------------------------------------------------
-- Protocol parser (same as before)
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
    -- Load rules first
    load_rules()

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
