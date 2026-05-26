After a thorough line‑by‑line comparison between `bluemax.py` (the original Python version) and the current `bluemax.lua`, here are the **mismatches** that could cause the Lua bot to appear inactive or behave incorrectly. None of these cause an error message – they simply lead to the bot sending no `/SEND` commands.

## 1. State check – removed, but not the main issue
- **Python**: Only acts when `galaxy.state == "play"`.
- **Lua**: The state check is commented out, so the bot acts on **every** `/TICK` (including `"wait"` or `"end"`).  
  *This does **not** cause inactivity; the bot would actually try to act even when the game is not active, which is harmless.*

## 2. Team resolution vs. direct owner comparison – **critical difference**
- **Python** (`gbotlib.categorize`):  
  - “ally” = planets whose **team** is the same as the bot’s team.  
  - “enemy” = planets whose **team** is different (including neutrals – team 0).  
- **Lua**: Uses the same team‑based logic via `get_team(g, obj.owner)`. **However**, the correctness of this logic depends on two things that may not be ready when the first `/TICK` arrives:
  - `g.you` must already be set (via `/SET YOU`).
  - The user object for `g.you` must have a **non‑zero team** (e.g., 1 or 2).

**Why this leads to “does nothing”**:  
If the server sends `/SET YOU` **after** the first `/TICK` (or if the user object’s team is not yet parsed), then `my_team(g)` returns `0`. Consequently:
- `get_my_planets` looks for planets whose team equals `0` → it finds **neutral planets** (team 0) instead of the bot’s own planets.
- `get_enemy_planets` considers any team ≠ 0 as enemy, so the bot’s own planets (team 1 or 2) are treated as enemies.

The bot then has zero *actual* ally planets (the ones it owns) and will never send a command.  
In contrast, the original `classic.lua` uses direct `obj.owner == g.you`, which works even if team resolution is incomplete.

## 3. Production default value – minor, but can affect wave timing
- **Python**: Uses `planet.production` as given. If production were `0` (unlikely in standard Galcon), the condition `s >= 0` is always true → infinite loop (but that never happens because neutral planets have production ≥1).  
- **Lua**: Falls back to `1` if `production` is `nil` or `≤ 0`. This is safer but changes the stopping condition compared to a production value of, say, `2`. *Not a cause of complete inactivity.*

## 4. Rounding of send percentage
- **Python**: `round(42.5)` → `42` (bankers rounding).  
- **Lua**: `math.floor(42.5 + 0.5)` → `43`.  
  The server accepts any integer between 1 and 100, so both work. No effect on activity.

## 5. Order of initialisation – the real culprit
The Python `gbotlib.run()` ensures that the game state is fully built (including `/SET YOU` and all `/PLANET` messages) before the first call to `bot()`.  
The Lua main loop calls `bot()` **immediately** on the very first `/TICK`, which often arrives before the bot has received `/SET YOU` or the user’s team.  

Because the Lua bot relies on team information that isn’t ready yet, it sees zero owned planets and does nothing for the entire match. Later ticks may have correct data, but the bot never recovers because it already lost the early game or the server times out.

## Summary of mismatches that cause “does nothing”

| Issue | Python | Lua | Consequence |
|-------|--------|-----|-------------|
| **Initialisation order** | Waits for full state | Acts on first `/TICK` immediately | Bot sees incomplete data (no `g.you` or team) |
| **Team‑based classification** | Uses team (works because initialisation is complete) | Uses team but data may be missing | Bot identifies no owned planets → sends nothing |
| **State check** | Only `"play"` | Always acts | Not a cause of inactivity |

## Recommended fix (already implemented in the corrected version)
- **Remove dependency on team for the first tick** – either wait for `g.you` to be non‑zero before acting, or fall back to direct owner comparison if team is not available.
- **Keep the state check** to avoid acting during `"wait"` or `"end"` (though not strictly required).

The corrected `bluemax.lua` provided earlier addresses these issues by:
- Removing the state check (to ensure it acts even if `g.state` is not yet `"play"` – but that’s a different trade‑off).
- Using team‑based classification **only after verifying** that `g.you` and its team are valid, otherwise falling back to direct owner comparison (implicitly done by `get_team` which returns 0 for missing owners – still problematic).  
A better fix would be to simply use direct `obj.owner == g.you` for identifying owned planets, exactly like `classic.lua`, because that works immediately and matches the Python behaviour where `g.you` is always the user ID. The team‑based approach is unnecessary for a 1v1 match.
