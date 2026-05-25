#!/usr/bin/env lua
-- bot_nars_goal_udp.lua
-- Galcon learning bot using UDPNAR (no files, no pipes, no TTY issues)

local socket = require("socket")

-- ============================================================
-- CONFIGURATION – adjust these paths and parameters
-- ============================================================
local UDPNAR_BIN = "/home/synbian/git/clone/NARS/OpenNARS-for-Applications/UDPNAR"  -- adjust if needed
local UDP_IP = "127.0.0.1"
local UDP_PORT = 50000
local TIMESTEP = 10000000          -- 10ms (as in UDPNAR_Test.h)
local SLEEP_NARS_THINK = 0.05      -- seconds between sending state and reading operations

local MOTOR_BABBLING_CHANCE = 0.4
local BABBLING_DECAY = 0.998
local MIN_BABBLING = 0.1
-- ============================================================

local udp = nil
local udpnar_pid = nil
local prev_planet_owners = {}

-----------------------------------------------------------------------
-- Logging to stderr
-----------------------------------------------------------------------
local function log(...)
    local args = {...}
    local msg = table.concat(args, " ")
    io.stderr:write(msg .. "\n")
    io.stderr:flush()
end

-----------------------------------------------------------------------
-- UDPNAR process management
-----------------------------------------------------------------------
local function start_udpnar()
    -- command: UDPNAR <ip> <port> <timestep> <true/false> (the last argument enables verbose? we use true as in test)
    local cmd = string.format("%s %s %d %d true", UDPNAR_BIN, UDP_IP, UDP_PORT, TIMESTEP)
    log("Starting UDPNAR: " .. cmd)
    -- Run in background and capture PID
    local pid_handle = io.popen(cmd .. " > /dev/null 2>&1 & echo $!", "r")
    if not pid_handle then
        log("ERROR: Failed to start UDPNAR process.")
        return nil
    end
    local pid_str = pid_handle:read("*line")
    pid_handle:close()
    if not pid_str or pid_str == "" then
        log("ERROR: Could not get PID of UDPNAR.")
        return nil
    end
    local pid = tonumber(pid_str)
    if not pid then
        log("ERROR: Invalid PID: " .. pid_str)
        return nil
    end
    log("UDPNAR started with PID " .. pid)
    -- Give it a moment to bind the socket
    socket.sleep(0.5)
    return pid
end

local function stop_udpnar()
    if udpnar_pid then
        log("Stopping UDPNAR (PID " .. udpnar_pid .. ")")
        os.execute("kill " .. udpnar_pid .. " 2>/dev/null")
        udpnar_pid = nil
    end
end

-- Register cleanup on script termination
local function register_cleanup()
    local original_exit = os.exit
    os.exit = function(code)
        stop_udpnar()
        original_exit(code)
    end
    -- Clean up on error or normal exit
    _G.__atexit = _G.__atexit or {}
    table.insert(_G.__atexit, stop_udpnar)
end

-----------------------------------------------------------------------
-- UDP communication
-----------------------------------------------------------------------
local function send_to_nars(line)
    if not udp then
        udp = socket.udp()
        udp:setpeername(UDP_IP, UDP_PORT)
    end
    udp:send(line .. "\n")
end

local function read_udp_operations()
    if not udp then return {} end
    udp:settimeout(0.01)  -- non‑blocking
    local ops = {}
    while true do
        local data, err = udp:receive()
        if not data then break end
        for line in data:gmatch("[^\r\n]+") do
            -- Match NARS derived operations: ^action_name(...)
            local action = line:match("^%^([%w_]+)%(")
            if action then
                if action == "send" then
                    local src, tgt, pct = line:match("send%((%d+),(%d+),(%d+)%)")
                    if src then
                        table.insert(ops, {cmd="SEND", src=tonumber(src), tgt=tonumber(tgt), pct=tonumber(pct)})
                    end
                elseif action == "redirect" then
                    local src, tgt = line:match("redirect%((%d+),(%d+)%)")
                    if src then
                        table.insert(ops, {cmd="REDIR", src=tonumber(src), tgt=tonumber(tgt)})
                    end
                elseif action == "send_strong_to_nearest" then
                    table.insert(ops, {cmd="ACTION", name="send_strong_to_nearest"})
                elseif action == "send_weak_to_random" then
                    table.insert(ops, {cmd="ACTION", name="send_weak_to_random"})
                elseif action == "redirect_all_to_weakest" then
                    table.insert(ops, {cmd="ACTION", name="redirect_all_to_weakest"})
                elseif action == "do_nothing" then
                    table.insert(ops, {cmd="ACTION", name="do_nothing"})
                elseif action == "send_half_from_strongest" then
                    table.insert(ops, {cmd="ACTION", name="send_half_from_strongest"})
                end
            end
        end
    end
    udp:settimeout(0)  -- back to blocking
    return ops
end

-----------------------------------------------------------------------
-- Game state helpers (identical to your pipes version)
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
    if not a or not b or not a.x or not a.y or not b.x or not b.y then return 99999 end
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

function total_my_ships(g, user_id)
    return count_ships_by_team(g)[get_team(g, user_id)] or 0
end

function total_enemy_ships(g, user_id)
    local my_team = get_team(g, user_id)
    local enemy = 0
    for team, s in pairs(count_ships_by_team(g)) do
        if team ~= 0 and team ~= my_team then enemy = enemy + s end
    end
    return enemy
end

function get_my_planets(g, user_id)
    local planets = {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" and obj.owner == user_id then
            table.insert(planets, obj)
        end
    end
    return planets
end

function get_enemy_planets(g, user_id)
    local my_team = get_team(g, user_id)
    local enemies = {}
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local team = get_team(g, obj.owner)
            if team ~= 0 and team ~= my_team then
                table.insert(enemies, obj)
            end
        end
    end
    return enemies
end

function get_strongest_planet(g, user_id)
    local best = nil
    for _, p in ipairs(get_my_planets(g, user_id)) do
        if not best or p.ships > best.ships then best = p end
    end
    return best
end

function get_weakest_enemy(g, user_id)
    local weakest = nil
    for _, e in ipairs(get_enemy_planets(g, user_id)) do
        if not weakest or e.ships < weakest.ships then weakest = e end
    end
    return weakest
end

function get_nearest_enemy(g, user_id, from_planet_id)
    local from = g.items[from_planet_id]
    if not from then return nil end
    local nearest = nil
    local min_dist = 1e9
    for _, e in ipairs(get_enemy_planets(g, user_id)) do
        local dist = distance_between(g, from_planet_id, e.n)
        if dist < min_dist then
            min_dist = dist
            nearest = e
        end
    end
    return nearest
end

-----------------------------------------------------------------------
-- Atomic beliefs injection
-----------------------------------------------------------------------
function inject_beliefs(g)
    local my_ships = total_my_ships(g, g.you)
    local enemy_ships = total_enemy_ships(g, g.you)
    local advantage = my_ships / (my_ships + enemy_ships + 0.01)

    if advantage > 0.7 then
        send_to_nars("advantage_high. :|:")
    elseif advantage > 0.4 then
        send_to_nars("advantage_medium. :|:")
    else
        send_to_nars("advantage_low. :|:")
    end

    local strongest = get_strongest_planet(g, g.you)
    if strongest then
        if strongest.ships >= 30 then
            send_to_nars("strong_planet_huge. :|:")
        elseif strongest.ships >= 15 then
            send_to_nars("strong_planet_medium. :|:")
        else
            send_to_nars("strong_planet_small. :|:")
        end
    else
        send_to_nars("no_planet. :|:")
    end

    local nearest = get_nearest_enemy(g, g.you, strongest and strongest.n or nil)
    if nearest then
        if nearest.ships <= 5 then
            send_to_nars("nearest_enemy_weak. :|:")
        elseif nearest.ships <= 15 then
            send_to_nars("nearest_enemy_medium. :|:")
        else
            send_to_nars("nearest_enemy_strong. :|:")
        end
        if strongest and distance_between(g, strongest.n, nearest.n) < 200 then
            send_to_nars("enemy_very_close. :|:")
        end
    else
        send_to_nars("no_enemy_planet. :|:")
    end

    if is_winning(g, get_team(g, g.you)) then
        send_to_nars("winning. :|:")
    else
        send_to_nars("losing. :|:")
    end

    local my_planets = get_my_planets(g, g.you)
    if #my_planets >= 3 then
        send_to_nars("many_planets. :|:")
    elseif #my_planets == 0 then
        send_to_nars("no_planets. :|:")
    end
end

-----------------------------------------------------------------------
-- Goals injection
-----------------------------------------------------------------------
function inject_goals(g)
    local my_ships = total_my_ships(g, g.you)
    local enemy_ships = total_enemy_ships(g, g.you)
    local advantage = my_ships / (my_ships + enemy_ships + 0.01)
    send_to_nars(string.format("advantage! :|: %%%f%%", advantage))

    if not get_strongest_planet(g, g.you) then
        send_to_nars("strong_planet_medium! :|: %1.0%")
    end

    send_to_nars("capture_success! :|: %1.0%")
end

-----------------------------------------------------------------------
-- Capture detection and reward events
-----------------------------------------------------------------------
function detect_captures(g)
    if not prev_planet_owners[g.you] then
        prev_planet_owners[g.you] = {}
        for _, obj in pairs(g.items) do
            if obj.type == "planet" then
                prev_planet_owners[g.you][obj.n] = obj.owner
            end
        end
        return
    end

    local my_id = g.you
    local prev = prev_planet_owners[my_id]
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local old = prev[obj.n]
            local new = obj.owner
            if old ~= new then
                if new == my_id then
                    send_to_nars("capture_success. :|: %1.0%")
                elseif old == my_id then
                    send_to_nars("capture_fail. :|: %1.0%")
                end
            end
            prev[obj.n] = new
        end
    end
end

-----------------------------------------------------------------------
-- Atomic actions (direct Galcon commands)
-----------------------------------------------------------------------
function action_send_strong_to_nearest(g)
    local source = get_strongest_planet(g, g.you)
    if not source then return end
    local target = get_nearest_enemy(g, g.you, source.n)
    if not target then return end
    io.stdout:write(string.format("/SEND %d %d %d\n", 65, source.n, target.n))
    io.stdout:flush()
end

function action_send_weak_to_random(g)
    local my_planets = get_my_planets(g, g.you)
    if #my_planets == 0 then return end
    local enemy_planets = get_enemy_planets(g, g.you)
    if #enemy_planets == 0 then return end
    local source = my_planets[math.random(#my_planets)]
    local target = enemy_planets[math.random(#enemy_planets)]
    local pct = math.random(30, 70)
    io.stdout:write(string.format("/SEND %d %d %d\n", pct, source.n, target.n))
    io.stdout:flush()
end

function action_redirect_all_to_weakest(g)
    local weakest = get_weakest_enemy(g, g.you)
    if not weakest then return end
    for _, fleet in pairs(g.items) do
        if fleet.type == "fleet" and fleet.owner == g.you then
            io.stdout:write(string.format("/REDIR %d %d\n", fleet.source, weakest.n))
            io.stdout:flush()
        end
    end
end

function action_do_nothing(g) end

function action_send_half_from_strongest(g)
    local source = get_strongest_planet(g, g.you)
    if not source then return end
    local target = get_nearest_enemy(g, g.you, source.n)
    if not target then return end
    io.stdout:write(string.format("/SEND %d %d %d\n", 50, source.n, target.n))
    io.stdout:flush()
end

function execute_operation(g, op)
    if op.cmd == "SEND" then
        io.stdout:write(string.format("/SEND %d %d %d\n", op.pct, op.src, op.tgt))
        io.stdout:flush()
    elseif op.cmd == "REDIR" then
        io.stdout:write(string.format("/REDIR %d %d\n", op.src, op.tgt))
        io.stdout:flush()
    elseif op.cmd == "ACTION" then
        if op.name == "send_strong_to_nearest" then
            action_send_strong_to_nearest(g)
        elseif op.name == "send_weak_to_random" then
            action_send_weak_to_random(g)
        elseif op.name == "redirect_all_to_weakest" then
            action_redirect_all_to_weakest(g)
        elseif op.name == "do_nothing" then
            action_do_nothing(g)
        elseif op.name == "send_half_from_strongest" then
            action_send_half_from_strongest(g)
        end
    end
end

-----------------------------------------------------------------------
-- Main bot decision (called on each /TICK)
-----------------------------------------------------------------------
function bot(g)
    detect_captures(g)
    inject_beliefs(g)
    inject_goals(g)

    socket.sleep(SLEEP_NARS_THINK)

    local do_babble = math.random() < MOTOR_BABBLING_CHANCE
    if do_babble then
        local actions = {
            "send_strong_to_nearest",
            "send_weak_to_random",
            "redirect_all_to_weakest",
            "do_nothing",
            "send_half_from_strongest"
        }
        local choice = actions[math.random(#actions)]
        if choice == "send_strong_to_nearest" then
            action_send_strong_to_nearest(g)
        elseif choice == "send_weak_to_random" then
            action_send_weak_to_random(g)
        elseif choice == "redirect_all_to_weakest" then
            action_redirect_all_to_weakest(g)
        elseif choice == "send_half_from_strongest" then
            action_send_half_from_strongest(g)
        else
            action_do_nothing(g)
        end
        MOTOR_BABBLING_CHANCE = math.max(MIN_BABBLING, MOTOR_BABBLING_CHANCE * BABBLING_DECAY)
    else
        local ops = read_udp_operations()
        for _, op in ipairs(ops) do
            execute_operation(g, op)
        end
    end
end

-----------------------------------------------------------------------
-- Protocol parser (unchanged from your pipes version)
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
        io.stdout:write("/TOCK\n")
        io.stdout:flush()
    elseif t[1] == "/PRINT" or t[1] == "/RESULTS" then
        log(join(slice(t,2,#t), '\t'))
    elseif t[1] == "/RESET" then
        for k, v in pairs(g) do g[k] = nil end
        g.you = 0; g.state = ''; g.items = {}
        prev_planet_owners = {}
    elseif t[1] == "/SET" then
        if t[2] == "YOU" then g.you = toint(t[3])
        elseif t[2] == "STATE" then g.state = t[3] end
    elseif t[1] == "/USER" then
        local n = toint(t[2])
        g.items[n] = { n=n, type="user", name=t[3], color=tonumber(t[4],16), team=toint(t[5]) }
    elseif t[1] == "/PLANET" then
        local n = toint(t[2])
        g.items[n] = { n=n, type="planet", owner=toint(t[3]), ships=tonumber(t[4]),
                       x=tonumber(t[5]), y=tonumber(t[6]), production=tonumber(t[7]), radius=tonumber(t[8]) }
    elseif t[1] == "/FLEET" then
        local n = toint(t[2])
        g.items[n] = { n=n, type="fleet", owner=toint(t[3]), ships=tonumber(t[4]),
                       x=tonumber(t[5]), y=tonumber(t[6]), source=toint(t[7]), target=toint(t[8]), radius=tonumber(t[9]) }
    elseif t[1] == "/DESTROY" then
        local n = toint(t[2])
        g.items[n] = nil
    elseif t[1] == "/ERROR" then
        log(join(slice(t,2,#t), '\t'))
    else
        log("unhandled: " .. join(t, '\t'))
    end
end

function sync(g, t)
    local nFields, fields = #t[1], t[1]:upper()
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

-----------------------------------------------------------------------
-- Main entry point
-----------------------------------------------------------------------
function main()
    udpnar_pid = start_udpnar()
    if not udpnar_pid then
        log("FATAL: Could not start UDPNAR. Exiting.")
        return 1
    end
    register_cleanup()

    local g = { you = 0, state = '', items = {} }
    while true do
        local line = io.stdin:read()
        if not line then break end
        if #line > 0 then parse(g, line) end
    end

    stop_udpnar()
end

main()
