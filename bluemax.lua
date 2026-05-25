#!/usr/bin/env lua
-- rewirte of bluemax from current code shared to my by ExaltedToast

-- bluemax.lua - Lua port of the Bluemax bot for Galcon
-- Based on the original Python version by ExaltedToast
package.path = package.path .. ";./?.lua"
local galcon = require("library")

-- Parameters (same as Python version)
local SEND_PROP = 0.425
local DELTA_PROP = 0.300
local HOLD_PROP = 0.200

-- Helper to round a number to nearest integer
local function round(x)
    return math.floor(x + 0.5)
end

-- Main bot logic
local function bot(g)
    -- Only act during active play
    if g.state ~= "play" then
        return
    end

    -- Get lists of planets
    local my_planets = galcon.get_my_planets(g, g.you)
    local enemy_planets = galcon.get_enemy_planets(g, g.you)

    if #enemy_planets == 0 then
        return
    end

    -- Sort enemy planets by production/(ships+1) descending (best targets first)
    table.sort(enemy_planets, function(a, b)
        local va = a.production / (a.ships + 1)
        local vb = b.production / (b.ships + 1)
        return va > vb
    end)

    -- For each friendly planet, send waves of ships
    for _, planet in ipairs(my_planets) do
        local ships = planet.ships
        local target_index = 0
        local num_targets = #enemy_planets

        -- Keep sending while we have enough ships to hold production
        while ships >= HOLD_PROP * planet.production do
            local target = enemy_planets[(target_index % num_targets) + 1]
            local percent = round(SEND_PROP * 100)
            galcon.send(string.format("/SEND %d %d %d", percent, planet.n, target.n))

            target_index = target_index + 1
            ships = ships * DELTA_PROP
        end
    end
end

-- Run the bot using the shared Galcon library
galcon.run(bot)
