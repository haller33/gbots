-- nars_learning_bot.lua (fixed)
-- Galcon bot that lets NARS learn from scratch using atomic beliefs, goals,
-- motor babbling, and reinforcement. No pre‑coded NAL rules.
-- Usage: gbots pipe -name nars_learning_bot -exec 'lua nars_learning_bot.lua'
-- Before starting, ensure a NARS process is running and reading input.nal
-- (e.g., ./NAR shell < input.nal > derived.nal &)

local input_file = "/home/synbian/git/clone/NARS/SemanticGraphSearch/input.nal"
local derived_file = "/home/synbian/git/clone/NARS/SemanticGraphSearch/derived.nal"

-- Configuration
local MOTOR_BABBLING_CHANCE = 0.3   -- initial exploration
local BABBLING_DECAY = 0.999        -- decay per tick
local MIN_BABBLING = 0.05
local SLEEP_NARS_THINK = 0.5       -- seconds to let NARS process

-- Store previous planet owners to detect captures
local prev_planet_owners = {}

-----------------------------------------------------------------------
-- Helper: cross‑platform sleep
-----------------------------------------------------------------------
local function sleep(seconds)
    if socket and socket.sleep then
        socket.sleep(seconds)
    else
        os.execute("sleep " .. seconds)
    end
end

-----------------------------------------------------------------------
-- File I/O for NARS communication
-----------------------------------------------------------------------
function write_to_nars(line)
    local f = io.open(input_file, "a")
    if f then
        f:write(line .. "\n")
        f:flush()
        f:close()
    end
end

function clear_input_file()
    local f = io.open(input_file, "w")
    if f then f:close() end
end

function read_nars_operations()
    local ops = {}
    local f = io.open(derived_file, "r")
    if not f then return ops end
    for line in f:lines() do
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
    f:close()
    return ops
end

function clear_derived()
    local f = io.open(derived_file, "w")
    if f then f:close() end
end

-----------------------------------------------------------------------
-- Game state helpers (adapted from classic.lua)
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
    -- Only planets and fleets have x,y; users don't
    if not a.x or not a.y or not b.x or not b.y then return 99999 end
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
    local ships = count_ships_by_team(g)
    return ships[get_team(g, user_id)] or 0
end

function total_enemy_ships(g, user_id)
    local my_team = get_team(g, user_id)
    local ships = count_ships_by_team(g)
    local enemy = 0
    for team, s in pairs(ships) do
        if team ~= 0 and team ~= my_team then enemy = enemy + s end
    end
    return enemy
end

function has_strong_planet(g, user_id)
    for _, obj in pairs(g.items) do
        if obj.type == "planet" and obj.owner == user_id and obj.ships >= 20 then
            return true
        end
    end
    return false
end

-- Find a source planet (my planet with >=17 ships and highest ship count)
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

-- Value = -ships + production - distance*0.20
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

-- Check if there exists an enemy planet with ships <= 10 within a certain distance of any of my planets
function nearest_enemy_weak(g, user_id)
    local my_team = get_team(g, user_id)
    local min_dist = 1e9
    -- Iterate over my planets
    for _, my_planet in pairs(g.items) do
        if my_planet.type == "planet" and my_planet.owner == user_id then
            for _, enemy in pairs(g.items) do
                if enemy.type == "planet" then
                    local enemy_team = get_team(g, enemy.owner)
                    if enemy_team ~= 0 and enemy_team ~= my_team and enemy.ships <= 10 then
                        local dist = distance_between(g, my_planet.n, enemy.n)
                        if dist < min_dist then min_dist = dist end
                    end
                end
            end
        end
    end
    return min_dist < 300
end

-----------------------------------------------------------------------
-- Capture detection and reward injection
-----------------------------------------------------------------------
function detect_captures(g)
    -- Initialize prev_planet_owners if first tick
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
            local old_owner = prev[obj.n]
            local new_owner = obj.owner
            if old_owner ~= new_owner then
                if new_owner == my_id then
                    -- We captured this planet
                    write_to_nars("capture_success. :|: %1.0%")
                elseif old_owner == my_id then
                    -- We lost this planet
                    write_to_nars("capture_fail. :|: %1.0%")
                end
            end
            prev[obj.n] = new_owner
        end
    end
end

-----------------------------------------------------------------------
-- Atomic belief injection
-----------------------------------------------------------------------
function inject_beliefs(g)
    local my_team = get_team(g, g.you)
    local my_ships = total_my_ships(g, g.you)
    local enemy_ships = total_enemy_ships(g, g.you)

    if my_ships > enemy_ships then
        write_to_nars("my_total_ships_gt_enemy. :|:")
    else
        write_to_nars("my_total_ships_lt_enemy. :|:")
    end

    if is_winning(g, my_team) then
        write_to_nars("winning. :|:")
    else
        write_to_nars("losing. :|:")
    end

    local weak = nearest_enemy_weak(g, g.you)
    if weak then
        write_to_nars("nearest_enemy_weak. :|:")
    else
        write_to_nars("nearest_enemy_strong. :|:")
    end

    if has_strong_planet(g, g.you) then
        write_to_nars("my_strong_planet_ready. :|:")
    else
        write_to_nars("my_strong_planet_idle. :|:")
    end
end

-----------------------------------------------------------------------
-- Goal injection (persistent and sub‑goals)
-----------------------------------------------------------------------
function inject_goals(g)
    local my_ships = total_my_ships(g, g.you)
    local enemy_ships = total_enemy_ships(g, g.you)
    local advantage = my_ships / (my_ships + enemy_ships + 0.01)

    write_to_nars(string.format("advantage! :|: %%%f%%", advantage))

    if not has_strong_planet(g, g.you) then
        write_to_nars("my_strong_planet_ready! :|: %1.0%")
    end

    if has_strong_planet(g, g.you) and not nearest_enemy_weak(g, g.you) then
        write_to_nars("nearest_enemy_weak! :|: %1.0%")
    end

    if my_ships < enemy_ships * 0.8 then
        write_to_nars("bad_situation. :|: %0.8%")
    end

    -- Always goal to capture planets
    write_to_nars("capture_success! :|: %1.0%")
end

-----------------------------------------------------------------------
-- Operation execution (direct Galcon commands)
-----------------------------------------------------------------------
function send_strongest_to_nearest(g)
    local source = find_attack_source(g, g.you)
    if source == 0 then return end
    local my_team = get_team(g, g.you)
    local winning = is_winning(g, my_team)
    local target = find_best_target(g, g.you, source, winning)
    if target and target ~= 0 then
        io.stdout:write(string.format("/SEND %d %d %d\n", 65, source, target))
        io.stdout:flush()
    end
end

function redirect_idle_fleets(g)
    local my_team = get_team(g, g.you)
    local winning = is_winning(g, my_team)
    for _, fleet in pairs(g.items) do
        if fleet.type == "fleet" and fleet.owner == g.you then
            local new_target = find_best_target(g, g.you, fleet.source, winning)
            if new_target and new_target ~= 0 and new_target ~= fleet.target then
                io.stdout:write(string.format("/REDIR %d %d\n", fleet.source, new_target))
                io.stdout:flush()
            end
        end
    end
end

function execute_operation(op)
    if op.cmd == "SEND" then
        io.stdout:write(string.format("/SEND %d %d %d\n", op.pct, op.src, op.tgt))
        io.stdout:flush()
    elseif op.cmd == "REDIR" then
        io.stdout:write(string.format("/REDIR %d %d\n", op.src, op.tgt))
        io.stdout:flush()
    end
end

-----------------------------------------------------------------------
-- Main bot decision (called every /TICK)
-----------------------------------------------------------------------
function bot(g)
    -- Detect captures and inject reward events
    detect_captures(g)

    -- Clear input.nal and write current state (beliefs + goals)
    -- clear_input_file()
    inject_beliefs(g)
    inject_goals(g)

    -- Give NARS time to process
    sleep(SLEEP_NARS_THINK)

    local do_babble = math.random() < MOTOR_BABBLING_CHANCE
    if do_babble then
        local actions = {"send_strongest_to_nearest", "redirect_idle_fleets"}
        local choice = actions[math.random(#actions)]
        if choice == "send_strongest_to_nearest" then
            send_strongest_to_nearest(g)
        elseif choice == "redirect_idle_fleets" then
            redirect_idle_fleets(g)
        end
        MOTOR_BABBLING_CHANCE = math.max(MIN_BABBLING, MOTOR_BABBLING_CHANCE * BABBLING_DECAY)
    else
        local ops = read_nars_operations()
        if #ops > 0 then
            for _, op in ipairs(ops) do
                execute_operation(op)
            end
        end
        -- clear_derived()
    end
end

-----------------------------------------------------------------------
-- Protocol parser (unchanged from classic.lua)
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
    elseif t[1] == "/PRINT" then
        io.stderr:write(join(slice(t,2,#t), '\t') .. '\n')
        io.stderr:flush()
    elseif t[1] == "/RESULTS" then
        io.stderr:write(join(slice(t,2,#t), '\t') .. '\n')
        io.stderr:flush()
    elseif t[1] == "/RESET" then
        for k, v in pairs(g) do g[k] = nil end
        g.you = 0; g.state = ''; g.items = {}
        prev_planet_owners = {}   -- reset capture tracking
    elseif t[1] == "/SET" then
        if t[2] == "YOU" then g.you = toint(t[3])
        elseif t[2] == "STATE" then g.state = t[3] end
    elseif t[1] == "/USER" then
        local n = toint(t[2])
        g.items[n] = {
            n = n, type = "user", name = t[3],
            color = tonumber(t[4], 16), team = toint(t[5]),
        }
    elseif t[1] == "/PLANET" then
        local n = toint(t[2])
        g.items[n] = {
            n = n, type = "planet", owner = toint(t[3]), ships = tonumber(t[4]),
            x = tonumber(t[5]), y = tonumber(t[6]), production = tonumber(t[7]),
            radius = tonumber(t[8]),
        }
    elseif t[1] == "/FLEET" then
        local n = toint(t[2])
        g.items[n] = {
            n = n, type = "fleet", owner = toint(t[3]), ships = tonumber(t[4]),
            x = tonumber(t[5]), y = tonumber(t[6]), source = toint(t[7]),
            target = toint(t[8]), radius = tonumber(t[9]),
        }
    elseif t[1] == "/DESTROY" then
        local n = toint(t[2])
        g.items[n] = nil
    elseif t[1] == "/ERROR" then
        io.stderr:write(join(slice(t,2,#t), '\t') .. '\n')
        io.stderr:flush()
    else
        io.stderr:write("unhandled command: " .. join(t, '\t') .. '\n')
        io.stderr:flush()
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
    -- clear_input_file()
    -- clear_derived()
    prev_planet_owners = {}

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
