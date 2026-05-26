#!/usr/bin/env python3
"""
Galcon Log Analyzer – processes one or multiple .log files and outputs:
- match_summary.csv  : per‑match stats
- tick_data.csv      : per‑tick ship & planet counts (for time‑series analysis)
"""

import os
import sys
import csv
import argparse
from collections import defaultdict

# ----------------------------------------------------------------------
# Parsing helpers
# ----------------------------------------------------------------------
def parse_fields_line(fields_str, obj_id_str, values):
    """Parse a differential update line like 'S 4 49' or 'SO 6 0 3'."""
    obj_id = int(obj_id_str)
    updates = {}
    for i, ch in enumerate(fields_str):
        val = values[i]
        if ch == 'X':
            updates['x'] = float(val)
        elif ch == 'Y':
            updates['y'] = float(val)
        elif ch == 'S':
            updates['ships'] = float(val)
        elif ch == 'R':
            updates['radius'] = float(val)
        elif ch == 'O':
            updates['owner'] = int(val)
        elif ch == 'T':
            updates['target'] = int(val)
    return obj_id, updates

def parse_log_file(filepath):
    """Parse a single log file and return a dict with match data."""
    # State
    users = {}          # user_id -> {'name':str, 'team':int}
    planets = {}        # planet_id -> {'owner':int, 'ships':float, 'production':float}
    fleets = {}         # fleet_id -> {'owner':int, 'ships':float, 'source':int, 'target':int}
    ticks = []          # list of dicts: {'tick_num':int, 'time':float, 'ships':{team:float}, 'planets':{team:int}}
    current_tick = None
    tick_num = 0
    winner = None
    duration = None
    bot_teams_by_id = {}   # user_id -> team

    def snapshot():
        nonlocal current_tick
        if current_tick is None:
            return
        # compute per‑team ships and planets from current planets
        team_ships = defaultdict(float)
        team_planets = defaultdict(int)
        for pid, p in planets.items():
            owner = p['owner']
            if owner == 0:
                continue
            team = users.get(owner, {}).get('team', owner)
            team_ships[team] += p['ships']
            team_planets[team] += 1
        # also add fleets (optional but more accurate)
        for fid, f in fleets.items():
            owner = f['owner']
            if owner == 0:
                continue
            team = users.get(owner, {}).get('team', owner)
            team_ships[team] += f['ships']
        current_tick['ships'] = dict(team_ships)
        current_tick['planets'] = dict(team_planets)
        ticks.append(current_tick)

    with open(filepath, 'r') as f:
        lines = f.readlines()

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue

        if line[0] == '/':
            parts = line.split('\t')
            cmd = parts[0]
            if cmd == '/RESET':
                users.clear()
                planets.clear()
                fleets.clear()
                ticks.clear()
                tick_num = 0
                current_tick = None
                winner = None
                duration = None
                bot_teams_by_id.clear()
            elif cmd == '/USER':
                if len(parts) >= 6:
                    uid = int(parts[1])
                    name = parts[2]
                    team = int(parts[4])
                    users[uid] = {'name': name, 'team': team}
                    bot_teams_by_id[uid] = team
            elif cmd == '/PLANET':
                if len(parts) >= 8:
                    pid = int(parts[1])
                    owner = int(parts[2])
                    ships = float(parts[3])
                    production = float(parts[6])
                    planets[pid] = {'owner': owner, 'ships': ships, 'production': production}
            elif cmd == '/FLEET':
                if len(parts) >= 10:
                    fid = int(parts[1])
                    owner = int(parts[2])
                    ships = float(parts[3])
                    source = int(parts[6])
                    target = int(parts[7])
                    fleets[fid] = {'owner': owner, 'ships': ships, 'source': source, 'target': target}
            elif cmd == '/DESTROY':
                if len(parts) >= 2:
                    fid = int(parts[1])
                    fleets.pop(fid, None)
            elif cmd == '/TICK':
                snapshot()
                tick_num += 1
                time_val = float(parts[1]) if len(parts) > 1 else 0.0
                current_tick = {'tick_num': tick_num, 'time': time_val, 'ships': {}, 'planets': {}}
            elif cmd == '/RESULTS':
                # /RESULTS timestamp duration mode num_players winner1,team1 winner2,team2 ...
                if len(parts) >= 6:
                    try:
                        duration = float(parts[2])
                    except:
                        duration = None
                    # last part: e.g. "<@1007:mixor>,2"
                    last = parts[-1]
                    if ',' in last:
                        w_team = int(last.split(',')[1])
                        for uid, info in users.items():
                            if info['team'] == w_team and info['name'] != 'neutral':
                                winner = info['name']
                                break
            elif cmd == '/SET':
                # ignore, but could log state
                pass
        else:
            # Differential update line (starts with letter fields)
            tokens = line.split()
            if len(tokens) < 2:
                i += 1
                continue
            fields_str = tokens[0]
            if not fields_str.isalpha():
                i += 1
                continue
            obj_id, updates = parse_fields_line(fields_str, tokens[1], tokens[2:])
            # apply updates to the right object
            if obj_id in planets:
                planets[obj_id].update(updates)
            elif obj_id in fleets:
                fleets[obj_id].update(updates)
        i += 1

    # final snapshot
    snapshot()

    # Determine bot names and teams (skip neutral)
    bot_list = []
    for uid, info in users.items():
        if info['name'] != 'neutral' and info['team'] != 0:
            bot_list.append((uid, info['name'], info['team']))
    bot_list.sort(key=lambda x: x[2])  # by team id

    bot1_name = bot_list[0][1] if len(bot_list) > 0 else 'unknown'
    bot2_name = bot_list[1][1] if len(bot_list) > 1 else 'unknown'
    bot1_team = bot_list[0][2] if len(bot_list) > 0 else None
    bot2_team = bot_list[1][2] if len(bot_list) > 1 else None

    # Initial and final ship counts
    initial_ships = {}
    final_ships = {}
    if ticks:
        first = ticks[0]['ships']
        last = ticks[-1]['ships']
        if bot1_team:
            initial_ships[bot1_team] = first.get(bot1_team, 0)
            final_ships[bot1_team] = last.get(bot1_team, 0)
        if bot2_team:
            initial_ships[bot2_team] = first.get(bot2_team, 0)
            final_ships[bot2_team] = last.get(bot2_team, 0)

    return {
        'filename': os.path.basename(filepath),
        'bot1': bot1_name,
        'bot2': bot2_name,
        'winner': winner if winner else 'draw',
        'duration': duration if duration else (ticks[-1]['time'] if ticks else 0),
        'num_ticks': len(ticks),
        'initial_ships_bot1': initial_ships.get(bot1_team, 0) if bot1_team else 0,
        'initial_ships_bot2': initial_ships.get(bot2_team, 0) if bot2_team else 0,
        'final_ships_bot1': final_ships.get(bot1_team, 0) if bot1_team else 0,
        'final_ships_bot2': final_ships.get(bot2_team, 0) if bot2_team else 0,
        'bot1_team': bot1_team,
        'bot2_team': bot2_team,
        'ticks': ticks,
        'users': users
    }

# ----------------------------------------------------------------------
# CSV writers
# ----------------------------------------------------------------------
def write_match_summary(matches, outfile):
    fieldnames = [
        'filename', 'bot1', 'bot2', 'winner', 'duration', 'num_ticks',
        'initial_ships_bot1', 'initial_ships_bot2',
        'final_ships_bot1', 'final_ships_bot2'
    ]
    with open(outfile, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for m in matches:
            row = {k: m.get(k, '') for k in fieldnames}
            writer.writerow(row)

def write_tick_data(matches, outfile):
    fieldnames = [
        'match_filename', 'tick_num', 'time',
        'bot1_ships', 'bot2_ships',
        'bot1_planets', 'bot2_planets'
    ]
    with open(outfile, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for m in matches:
            bot1_team = m.get('bot1_team')
            bot2_team = m.get('bot2_team')
            if bot1_team is None or bot2_team is None:
                continue
            for tick in m.get('ticks', []):
                ships = tick.get('ships', {})
                planets = tick.get('planets', {})
                row = {
                    'match_filename': m['filename'],
                    'tick_num': tick['tick_num'],
                    'time': tick['time'],
                    'bot1_ships': ships.get(bot1_team, 0),
                    'bot2_ships': ships.get(bot2_team, 0),
                    'bot1_planets': planets.get(bot1_team, 0),
                    'bot2_planets': planets.get(bot2_team, 0),
                }
                writer.writerow(row)

# ----------------------------------------------------------------------
# Main – supports both single file and directory
# ----------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description='Analyze Galcon log files (single file or directory).')
    parser.add_argument('input', help='Log file or directory containing .log files')
    parser.add_argument('--output', '-o', default='.', help='Output directory for CSV files')
    args = parser.parse_args()

    input_path = args.input
    output_dir = args.output
    os.makedirs(output_dir, exist_ok=True)

    # Collect log files
    if os.path.isfile(input_path):
        log_files = [input_path]
    elif os.path.isdir(input_path):
        log_files = [os.path.join(input_path, f) for f in os.listdir(input_path) if f.endswith('.log')]
    else:
        print(f"Error: {input_path} is not a file or directory", file=sys.stderr)
        sys.exit(1)

    if not log_files:
        print("No .log files found.", file=sys.stderr)
        sys.exit(1)

    matches = []
    for lf in log_files:
        print(f"Processing {os.path.basename(lf)}...")
        matches.append(parse_log_file(lf))

    # Write CSVs
    summary_csv = os.path.join(output_dir, 'match_summary.csv')
    tick_csv = os.path.join(output_dir, 'tick_data.csv')
    write_match_summary(matches, summary_csv)
    write_tick_data(matches, tick_csv)
    print(f"Done. Wrote:\n  {summary_csv}\n  {tick_csv}")

if __name__ == '__main__':
    main()
