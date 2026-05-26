An exhaustive line-by-line comparison between the original Python implementation (`bluemax.py`) and the Lua re-implementation (`bluemax.lua`), cross-referenced with the Galcon BOTS protocol documentation, reveals several critical discrepancies.

While the previous LLM report correctly identified general symptoms, it missed the true systemic defects within the code. Below is the definitive breakdown of the mismatches causing the Lua bot's malfunction and behavioral differences.

---

## 1. The Critical Team Resolution Bug (The Real Cause of Inactivity)

The most severe defect in `bluemax.lua` resides in how it filters allied and enemy planets. It completely paralyzes the bot in standard 1v1 or Free-For-All (FFA) matches.

* **Python Implementation:** Uses `gbotlib.categorize(galaxy, "planets")`. In standard Galcon frameworks, this categorizes planets based on **direct ownership** (`planet.owner == galaxy.you` for allies, and everything else as enemies/neutrals). This functions perfectly regardless of whether teams are explicitly configured.
* **Lua Re-implementation:** Implements a custom team-lookup function (`get_team`) and filters planets like this:
```lua
if owner_team == my_t and owner_team ~= 0 then ...

```


* **The Mismatch:** According to `faq.md`, a team value of `0` denotes neutrality (`isNeutral := (Items[planet.Owner].Team == 0)`). In standard non-team matches, player teams also default to `0`.
Because of the strict `and owner_team ~= 0` check, if the bot is on team `0`, **it completely fails to recognize its own planets**. `get_my_planets` returns an empty table on every single tick, rendering the bot entirely frozen for the whole match.

---

## 2. Numerical Rounding Mismatch (Fleet Size Divergence)

The two languages handle floating-point rounding differently, altering the exact percentage of ships commanded to move.

* **Python Implementation:** Uses Python 3’s native `round()`, which employs **Banker's Rounding** (rounds half-values to the nearest even integer). For `SEND_PROP = 0.425`, `round(42.5)` evaluates to **`42`**. The bot sends `/SEND 42 ...`.
* **Lua Re-implementation:** Implements a standard rounding helper:
```lua
local function round(x) return math.floor(x + 0.5) end

```


For `42.5`, this evaluates to **`43`**. The bot sends `/SEND 43 ...`. While both are valid syntax under `protocol.md`, the Lua bot consistently sends slightly larger attack waves than its Python counterpart.

---

## 3. Game State Check Bypass

* **Python Implementation:** Safeguards execution with `if galaxy.state == "play":`. It explicitly ignores ticks broadcast during the lobby, countdown, or post-game screen.
* **Lua Re-implementation:** The state check has been commented out. This forces the bot to process strategy and attempt to issue `/SEND` commands during setup or wrap-up phases. This can result in spamming the server with invalid moves and triggering `/ERROR` responses.

---

## 4. Sorting Stability and Target Cycling

* **Python Implementation:** Uses Python's built-in `sorted()`, which is powered by Timsort—a **stable** sorting algorithm. If multiple neutral planets have identical production-to-ship ratios at the start of a match, Python preserves their original order from the server.
* **Lua Re-implementation:** Employs `table.sort`, which uses an **unstable** quicksort variant. Planets with identical values can be shuffled arbitrarily depending on the Lua runtime environment. This alters the cycling order (`targets[(idx % num_targets) + 1]`) and causes the two bots to target entirely different planets on opening moves.

---

## 5. Production Safety Loop Fallback

* **Python Implementation:** Lacks any defensive fallbacks. If a planet's production is ever `0`, the condition `while s >= HOLD_PROP * planet.production` simplifies to `while s >= 0`. Because `s` decays exponentially by `0.300`, it will never drop below 0, trapping the Python bot in a fatal **infinite loop**.
* **Lua Re-implementation:** Features a defensive fallback clause:
```lua
local prod = (planet.production and planet.production > 0) and planet.production or 1

```


This shields the Lua version from hanging if a planet has 0 production. However, this safety check is missing inside the Lua `table.sort` block; if `production` fields are omitted or `nil` during a tick update, the sorting function will throw a fatal arithmetic runtime error.

---

## 6. Carriage Return (`\r`) Stream Poisoning

* **Python Implementation:** The underlying `gbotlib` handles cross-platform stream boundaries seamlessly, cleanly separating commands by `\n` while discarding Windows-style carriage returns (`\r`).
* **Lua Re-implementation:** Uses raw `io.stdin:read()`. If the game server communicates using `\r\n` line endings, the trailing `\r` remains attached to the final token parsed in a message. For instance, `/SET STATE play\r` saves the state string as `"play\r"`. If you uncomment the state check in Lua later, string comparisons like `g.state == "play"` will fail silently.

---

## Summary Comparison Matrix

| Feature / Logic | Python (`bluemax.py`) | Lua (`bluemax.lua`) | Operational Impact |
| --- | --- | --- | --- |
| **Planet Filtering** | Direct Ownership / `gbotlib` | Team Lookup (`owner_team ~= 0`) | **Fatal:** The Lua bot treats its own planets as non-existent if player teams default to `0`. |
| **Rounding (42.5%)** | Banker's Rounding (`42`) | Standard Rounding (`43`) | Lua bot dispatches slightly larger attack vectors. |
| **State Handling** | Enforces `"play"` check | Processes all states | Lua bot sends redundant actions during warmups/ends. |
| **Sort Stability** | Stable (Preserves server order) | Unstable (Shuffles matches) | Divergent opening-game target targeting patterns. |
| **0-Production Map** | Infinite Loop (Game hangs) | Safe Fallback (Becomes `1`) | Lua handles custom 0-prod map constraints safer. |
| **Line Endings** | Handles `\r\n` automatically | Keeps trailing `\r` literals | Destroys string validation if network uses `\r\n`. |
