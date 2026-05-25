# 🤖 gbots – Galcon Bot Framework & AI Playground

This repository is a collection of tools, libraries, and AI agents for the real‑time strategy game **Galcon**. It provides everything you need to develop, test, and pit autonomous bots against each other: from simple scripted agents to advanced learning bots powered by the [OpenNARS](https://github.com/opennars/OpenNARS) reasoning system.

## ✨ Features

* **Complete Bot Library** – A reusable Lua module (`library.lua`) that handles the entire Galcon protocol. It gives you a clean interface to the game state, so you can focus entirely on your bot’s strategy.
* **Pre‑built Bots** – Ready‑to‑run examples to get you started:
  * `classic.lua` – A solid, heuristic‑based bot (the classic Galcon AI).
  * `bluemax.lua` – A Lua port of the well‑known Bluemax bot from ExaltedToast.
  * Random bots in Python, Go, and Lua for baseline testing.
* **NARS‑Powered Learning Bots** – Several bots that connect to the OpenNARS reasoner via UDP or pipes. They learn online through motor babbling and are rewarded for capturing planets. The `v2` versions have richer beliefs and more actions.
* **Fast C99 Simulator** – A headless server & client written in C. It can run thousands of matches per second, making it perfect for rapid statistical testing and tournament hosting.
* **Multi‑Language Support** – Example bots in **Lua**, **Python**, and **Go**, showing how to implement the Galcon protocol in any language.
* **Full Protocol Documentation** – The `protocol.md` and `actions.md` files detail every server‑client message and command.

## 🚀 Getting Started

### 1. Prerequisites

* **Lua 5.2+** (for Lua bots)
* **Python 3** (for Python bots)
* **Go** (for Go bots)
* **Galcon BOTS** – The official `gbots` launcher, server, and pipe tool. Get it from [galcon.com](https://www.galcon.com/bots/).

### 2. Clone the Repository

```bash
git clone https://github.com/haller33/gbots.git
cd gbots
```

### 3. Run a Bot

Use the `gbots pipe` tool to launch a bot. For example, to run the `classic.lua` bot:

```bash
gbots pipe -name classic -exec 'lua classic.lua'
```

To run the `bluemax` bot:

```bash
gbots pipe -name bluemax -exec 'lua bluemax.lua'
```

> **Note**: The Lua bots use `library.lua` as a shared module. The `package.path` modification at the top of each bot ensures that Lua can find it.

### 4. Run the Simulator (C99)

Compile the fast headless server:

```bash
gcc -O3 -o galcon galcon.c -lm -pthread
```

Then start a match test between `classic` and `random`:

```bash
./galcon test classic random 1000
```

This will run 1000 matches and print win/draw statistics.

## 📚 Bot Examples

| File | Language | Description |
|------|----------|-------------|
| `classic.lua` | Lua | The traditional Galcon bot. It sends 65% from its strongest planet (≥17 ships) to the best‑valued target (production, distance, enemy strength). |
| `bluemax.lua` | Lua | Port of the popular Bluemax bot. It sorts enemy planets by `production/(ships+1)` and sends waves of ships from all its planets. |
| `bot_nars_goal_udp.v2.lua` | Lua | Advanced learning bot that connects to OpenNARS via UDP. It injects fine‑grained beliefs (advantage levels, ship counts, production) and can choose from 10 different actions. |
| `bot.py` | Python | A simple random bot. |
| `bot.go` | Go | Another random bot written in Go. |

## 📡 Galcon Protocol

The `protocol.md` file in this repo is the official specification. It defines every message exchanged between the server and a bot. Some key messages:

* **Server → Bot**:
  * `/TICK` – A turn has started. The bot should act and reply with `/TOCK`.
  * `/PLANET id owner ships x y production radius` – A planet update.
  * `/FLEET id owner ships x y source target radius` – A fleet update.
  * `/RESET` – The game has reset.
* **Bot → Server**:
  * `/SEND percent source target` – Launch a fleet from `source` to `target`, using `percent`% of the source planet’s ships.
  * `/REDIR source target` – Redirect all fleets from `source` to a new `target`.

The `actions.md` file explains how to use the `gbots` command‑line tools (server, client, pipe, replay).

## 🧠 Advanced Bots: NARS

The NARS‑based bots (`bot_nars_goal_udp.v2.lua`, etc.) are learning agents that use the [OpenNARS](https://github.com/opennars/OpenNARS) non‑axiomatic reasoning system. They work as follows:

1. **Perception** – The bot receives the game state and injects **beliefs** (e.g., `advantage_medium`, `enemy_closest_weak`) as NARSese sentences.
2. **Goals** – It also injects **goals** like `advantage!` (with priority equal to the current ship advantage) and `capture_success!`.
3. **Reasoning** – The bot waits for NARS to derive an operation (e.g., `^send_strong_to_nearest`).
4. **Action** – The operation is translated into a Galcon `/SEND` or `/REDIR` command.
5. **Motor Babbling** – Early in the game, the bot sometimes takes random actions to explore. The babble probability decays over time.
6. **Reward** – When a capture occurs, `capture_success. :|: %1.0%` is injected, providing immediate feedback.

To run a NARS bot, you need the `UDPNAR` binary (included as a Git submodule). The bot will start it automatically.

## 🏎️ Fast Simulator (C99)

The file `galcon.c` implements a complete, headless Galcon server and client in C. It is designed for **high‑throughput testing**:

* **Server mode** – Listens for bot connections over TCP and simulates the game.
* **Client mode** – Connects to a server and runs a built‑in bot (e.g., `classic`).
* **Test mode** – Runs many matches in‑process without any network overhead. This is ideal for statistical analysis.

The simulator supports the core Galcon mechanics: planet production, fleet movement, combat, captures, and redirection.

## 🤝 Contributing

Contributions are welcome! If you have a new bot, an improvement to the library, or a bug fix, feel free to open a pull request. Please follow the existing style (Lua, Python, Go) and ensure that your bot works with the `gbots pipe` tool.

## 📜 License

This project is licensed under the MIT License – see the `LICENSE` file for details (if present). The Galcon BOTS tools and protocol are copyright of Phil Hassey.

## 🙏 Acknowledgements

* Phil Hassey for creating Galcon and the `gbots` framework.
* ExaltedToast for the original Bluemax bot.
* The OpenNARS team for the reasoning system.

---

Happy bot battling! 🚀
