-- nars_learning_bot.lua
-- Galcon bot that lets NARS learn from scratch using atomic beliefs, goals,
-- motor babbling, and reinforcement. No pre‑coded NAL rules.
-- Usage: gbots pipe -name nars_learning_bot -exec 'lua nars_learning_bot.lua'
-- Before starting, ensure a NARS process is running and reading input.nal
-- (e.g., ./NAR shell < input.nal > derived.nal &)

local input_file = "input.nal"
local derived_file = "derived.nal"

-- Configuration
local MOTOR_BABBLING_CHANCE = 0.3   -- initial exploration
local BABBLING_DECAY = 0.999        -- decay per tick
local MIN_BABBLING = 0.05
local SLEEP_NARS_THINK = 0.05       -- seconds to let NARS process

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
        -- Look for ^send or ^redirect commands
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

function nearest_enemy_weak(g, user_id)
    -- find nearest enemy planet with ships <= 10
    local my_team = get_team(g, user_id)
    local best_dist = 1e9
    for _, obj in pairs(g.items) do
        if obj.type == "planet" then
            local owner_team = get_team(g, obj.owner)
            if owner_team ~= 0 and owner_team ~= my_team and obj.ships <= 10 then
                local dist = distance_between(g, user_id, obj.n) -- rough approximation
                if dist < best_dist then best_dist = dist end
            end
        end
    end
    return best_dist < 300   -- threshold for "weak"
end

-----------------------------------------------------------------------
-- Atomic belief injection
-----------------------------------------------------------------------
function inject_beliefs(g)
    local my_team = get_team(g, g.you)
    local my_ships = total_my_ships(g, g.you)
    local enemy_ships = total_enemy_ships(g, g.you)

    -- Relative strength
    if my_ships > enemy_ships then
        write_to_nars("my_total_ships_gt_enemy. :|:")
    else
        write_to_nars("my_total_ships_lt_enemy. :|:")
    end

    -- Winning / losing
    if is_winning(g, my_team) then
        write_to_nars("winning. :|:")
    else
        write_to_nars("losing. :|:")
    end

    -- Nearest enemy planet properties (simplified)
    -- For a real bot you would compute actual nearest enemy planet
    local weak = nearest_enemy_weak(g, g.you)
    if weak then
        write_to_nars("nearest_enemy_weak. :|:")
    else
        write_to_nars("nearest_enemy_strong. :|:")
    end

    -- My strongest planet readiness
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

    -- Persistent goal: high advantage (truth value)
    write_to_nars(string.format("advantage! :|: %f%%", advantage * 100))

    -- Sub‑goal: build a strong planet if none exists
    if not has_strong_planet(g, g.you) then
        write_to_nars("my_strong_planet_ready! :|: 100%")
    end

    -- Sub‑goal: attack a weak enemy if we have a strong planet
    if has_strong_planet(g, g.you) and not nearest_enemy_weak(g, g.you) then
        write_to_nars("nearest_enemy_weak! :|: 100%")
    end

    -- Negative feedback for losing
    if my_ships < enemy_ships * 0.8 then
        write_to_nars("bad_situation. :|: 80%")
    end
end

-----------------------------------------------------------------------
-- Operation execution (direct Galcon commands)
-----------------------------------------------------------------------
function send_strongest_to_nearest(g)
    local source = find_attack_source(g, g.you)   -- from classic.lua logic
    if not source then return end
    local my_team = get_team(g, g.you)
    local winning = is_winning(g, my_team)
    local target = find_best_target(g, g.you, source, winning)
    if target and target ~= 0 then
        io.stdout:write(string.format("/SEND %d %d %d\n", 65, source, target))
        io.stdout:flush()
    end
end

function redirect_idle_fleets(g)
    -- redirect all fleets owned by me to a better target
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
    -- 1. Clear input.nal and write current state (beliefs + goals)
    clear_input_file()
    inject_beliefs(g)
    inject_goals(g)

    -- 2. Give NARS time to process
    sleep(SLEEP_NARS_THINK)

    -- 3. Motor babbling: random action with probability BABBLING_CHANCE
    local do_babble = math.random() < MOTOR_BABBLING_CHANCE
    if do_babble then
        -- choose a random valid operation
        local actions = {"send_strongest_to_nearest", "redirect_idle_fleets"}
        local choice = actions[math.random(#actions)]
        if choice == "send_strongest_to_nearest" then
            send_strongest_to_nearest(g)
        elseif choice == "redirect_idle_fleets" then
            redirect_idle_fleets(g)
        end
        -- Decay babblings chance
        MOTOR_BABBLING_CHANCE = math.max(MIN_BABBLING, MOTOR_BABBLING_CHANCE * BABBLING_DECAY)
    else
        -- 4. Read operations from derived.nal (NARS's decisions)
        local ops = read_nars_operations()
        if #ops > 0 then
            for _, op in ipairs(ops) do
                execute_operation(op)
            end
        else
            -- No operation from NARS – optionally do nothing or a default action
            -- Here we do nothing to let NARS learn that inaction may not lead to rewards
        end
        -- Clear derived.nal to avoid reprocessing
        clear_derived()
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
    -- Clear communication files at start
    clear_input_file()
    clear_derived()

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
