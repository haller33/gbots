### Encoding Galcon Logic for Emergent NARS Learning (like the C tests)

You want NARS to **learn** Galcon strategies from scratch – just like the Pong, Robot, and Cartpole examples – using only atomic symbols, operations, and reward signals. No pre‑coded NAL rules. This is possible but requires careful abstraction of the game state and a suitable learning loop.

Below I list the **best ways** to translate Galcon’s continuous, multi‑entity world into the discrete, event‑driven world that NARS understands, and how to set up the environment so NARS can discover good policies through experience.

---

### 1. Define Atomic Perceptions (Beliefs)

In the C tests, the robot sees `l_f`, `m_w`, `r_o` – three atomic symbols representing left/middle/right view.  
For Galcon, you need to reduce the complex state to a **small set of boolean or categorical facts** that are meaningful for decision making.

**Suggested atomic beliefs** (injected at each tick):

```lua
-- Relative strength
"my_total_ships_gt_enemy. :|:"
"my_total_ships_lt_enemy. :|:"

-- Nearest enemy planet properties
"nearest_enemy_close. :|:"        -- distance < some threshold
"nearest_enemy_far. :|:"
"nearest_enemy_weak. :|:"         -- ships <= 10
"nearest_enemy_strong. :|:"       -- ships > 30

-- My strongest planet
"my_strong_planet_ready. :|:"     -- ships >= 20
"my_strong_planet_idle. :|:"

-- Winning condition
"winning. :|:"                    -- my_ships > 2 * enemy_ships
"losing. :|:"
```

You can also encode numeric comparisons as separate atoms:  
`enemy_ships_0_10.`, `enemy_ships_11_20.`, etc.  
This is exactly how Pong encodes `ball_left` / `ball_right` – no numbers, just categories.

**Why this works** – NARS can learn temporal implications like:  
`<(&/, nearest_enemy_weak, my_strong_planet_ready) =/> send_from_strong_to_nearest>`

---

### 2. Define Atomic Operations (Actions)

The Galcon API allows `/SEND percentage source target` and `/REDIR source new_target`.  
These must be wrapped as NARS operations with **no arguments** (or with simple constants) because the C tests use zero‑argument callbacks.

**Suggested atomic operations** (register each with `NAR_AddOperation`):

- `^send_from_strongest_to_nearest` – chooses the source and target automatically inside the Lua callback.
- `^send_from_strongest_to_weakest_enemy`
- `^redirect_idle_fleets` – redirects all fleets that are not yet committed.
- `^wait` – do nothing (useful for motor babbling).

The Lua callback will:
- Query the current game state (using the `g` table) to determine the actual source/target IDs.
- Execute the corresponding `/SEND` or `/REDIR` command.
- Return a `Feedback` (unused, but needed for compatibility).

Example callback:

```lua
function nars_send_strongest_to_nearest()
    local source = find_attack_source(g, g.you)   -- from classic.lua
    local target = find_best_target(g, g.you, source, is_winning(g, user_team))
    if source and target then
        send(string.format("/SEND %d %d %d", 65, source, target))
    end
    return {0}
end
```

---

### 3. Provide Reinforcement Signals (Goals)

In the C tests, the robot gets `eaten. :|:` (reward) when it touches food, and the goal `eaten! :|:` is always active.  
Cartpole gets `good. :|:` when the pole is balanced, and `good! :|:` as the goal.

For Galcon, define **intermediate rewards** that NARS can learn to maximise:

```lua
-- When you capture an enemy or neutral planet
if captured_planet then
    NAR_AddInputBelief("capture_success. :|:")   -- positive feedback
end

-- When you lose a planet
if lost_planet then
    NAR_AddInputBelief("capture_fail. :|:")      -- negative feedback
end

-- Always active goal
NAR_AddInputGoal("capture_success!")
```

You can also use a **continuous success metric** like the ratio of your ships to enemy ships.  
In Cartpole, `good. :|: %50%` gives a probabilistic truth value – you can do the same:

```lua
local my_ships = count_ships_by_team(g)[user_team] or 0
local enemy_ships = total_enemy_ships(g)
local advantage = my_ships / (my_ships + enemy_ships)   -- between 0 and 1
NAR_AddInputBelief(string.format("advantage. :|: %f%%", advantage * 100))
NAR_AddInputGoal("advantage!")
```

Now NARS learns to perform actions that increase `advantage` over time.

---

### 4. Implement Motor Babbling (Exploration)

In the C tests, `MOTOR_BABBLING_CHANCE` makes NARS execute random operations initially. You can emulate this in your Lua loop **before** sending the state to NARS:

```lua
if math.random() < MOTOR_BABBLING_CHANCE then
    local ops = {"^send_from_strongest_to_nearest", "^redirect_idle_fleets", "^wait"}
    local random_op = ops[math.random(#ops)]
    -- execute directly, bypass NARS decision
    if random_op == "^send_from_strongest_to_nearest" then
        nars_send_strongest_to_nearest()
    elseif ...
end
```

After many cycles, reduce the babblings chance to zero, allowing NARS to take over.

---

### 5. Use Temporal Sequences (&/) and Predictive Implications

The C tests teach sequences like: `a → ^op → result`.  
For Galcon, you want NARS to learn that performing an action in a certain context leads to a reward.

Example learning loop (pseudo‑code):

```lua
-- At each tick:
-- 1. Send current beliefs (e.g., "nearest_enemy_weak")
-- 2. Send the reward/goal ("capture_success!")
-- 3. Let NARS decide which operation to execute (via operation callbacks)
-- 4. Execute the chosen operation in the game
-- 5. After the operation, send the outcome belief ("capture_success" or "capture_fail")
-- 6. Repeat
```

Over time, NARS will build implications like:  
`<(&/, nearest_enemy_weak, ^send_from_strongest_to_nearest) =/> capture_success>`  
and then use backward inference (`capture_success!` goal) to execute the operation.

---

### 6. Simplify the State Space – Quantisation

The C tests use **coarse quantisation**:  
- Robot direction: 8 possible symbols.  
- Cartpole angle: encoded as an integer `0..7`.  
- Pong ball position: only `ball_left` or `ball_right`.

For Galcon, you should **not** send exact ship numbers or coordinates. Instead, quantise:

| Continuous value | Atomic symbols |
|----------------|----------------|
| Distance to nearest enemy | `enemy_close` (< 200), `enemy_medium` (200‑400), `enemy_far` (>400) |
| My planet’s ships | `weak` (<10), `medium` (10‑30), `strong` (>30) |
| Enemy planet’s ships | `undefended` (<5), `defended` (5‑20), `fortified` (>20) |

You can generate these from the game state before each NARS input.

---

### 7. Start with a Sub‑Problem (like Pong’s simple goal)

In Pong, the only goal is `good_nar!` (hit the ball).  
For Galcon, start with a **simplified scenario**:
- Only two planets: your home planet and one enemy planet.
- No fleets, only direct send actions.
- Goal: `capture_enemy_planet!`

Once NARS learns that `^send_all_ships` leads to `capture_success`, you can add more planets and redirect actions.

---

### 8. Example: Mapping Galcon to Pong‑like Perceptions

Pong’s perception: `ball_left` / `ball_right` → action `^left` or `^right`.  
Galcon equivalent:

```lua
-- Quantised advantage
if my_ships > enemy_ships * 1.5 then
    NAR_AddInputBelief("advantage_high. :|:")
elseif my_ships < enemy_ships * 0.5 then
    NAR_AddInputBelief("advantage_low. :|:")
else
    NAR_AddInputBelief("advantage_equal. :|:")
end

-- Nearest enemy distance quantised
local dist = distance_to_nearest_enemy(g, g.you)
if dist < 200 then
    NAR_AddInputBelief("enemy_near. :|:")
elseif dist < 400 then
    NAR_AddInputBelief("enemy_medium. :|:")
else
    NAR_AddInputBelief("enemy_far. :|:")
end

-- Goal: always advantage_high!
NAR_AddInputGoal("advantage_high!")
```

Now NARS will learn to perform actions that move from `advantage_low` or `advantage_equal` toward `advantage_high`.

---

### Summary Table – C Test Patterns vs Galcon Adaptation

| C Test Pattern | Galcon Adaptation |
|----------------|-------------------|
| Atomic perceptions (e.g., `l_f`, `m_w`) | `enemy_near`, `my_strong`, `advantage_low` |
| Atomic operations (`^left`, `^forward`) | `^send_strong_to_nearest`, `^redirect_idle` |
| Reward belief (`eaten. :|:`) | `capture_success. :|:` |
| Always‑active goal (`eaten! :|:`) | `advantage! :|:` or `capture_success!` |
| Motor babbling (`MOTOR_BABBLING_CHANCE`) | Randomly execute actions at start |
| Temporal learning through repetition | Run many game ticks (thousands) with state/goal input each tick |
| No hard‑coded rules | No NAL files – only initial emptiness |

---

### Important Caveat

Galcon is **much more complex** than Pong or the robot maze. Learning purely from scratch will require **very many episodes** (hundreds of thousands of ticks) because the state space is larger and rewards are delayed. You can speed it up by:

- Using **shaped rewards** (e.g., give small positive feedback for any increase in `advantage`).
- Starting with **sub‑goals** (capture one planet, then two).
- Combining **motor babbling with a simple heuristic** (like `classic.lua`) for the first few thousand ticks, then slowly fading it out – this is what the C tests do implicitly by initially presenting sequences of correct actions (e.g., `a`, `^1`, `g` in `Sequence_Test`).

But the **principle is sound**: NARS can learn Galcon strategies emergently if you provide the right atomic building blocks and sufficient exploration.

