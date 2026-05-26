#!/usr/bin/env python3
"""
Galcon Log Analyzer – Plotting Module
Reads match_summary.csv and tick_data.csv, generates performance plots.

Usage:
    python plot_galcon_stats.py [--match-summary MATCH_SUMMARY.csv] [--tick-data TICK_DATA.csv] [--output-dir OUTPUT_DIR]
"""

import argparse
import os
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from pathlib import Path

# Set style for better visuals
plt.style.use('seaborn-v0_8-darkgrid')
plt.rcParams['figure.figsize'] = (12, 6)


def load_data(match_summary_path, tick_data_path):
    """Load CSV files into pandas DataFrames."""
    match_df = pd.read_csv(match_summary_path)
    tick_df = pd.read_csv(tick_data_path)
    return match_df, tick_df


def plot_win_counts(match_df, output_dir):
    """Bar chart of wins per bot."""
    winners = match_df['winner'].value_counts()
    plt.figure()
    ax = winners.plot(kind='bar', color=['green', 'red', 'gray'], edgecolor='black')
    plt.title('Match Wins by Bot', fontsize=14)
    plt.xlabel('Bot')
    plt.ylabel('Number of Wins')
    plt.xticks(rotation=0)
    for i, v in enumerate(winners.values):
        ax.text(i, v + 0.1, str(v), ha='center', va='bottom')
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'win_counts.png'), dpi=150)
    plt.close()


def plot_ship_advantage_over_time(tick_df, output_dir):
    """Plot ship advantage (bot1_ships - bot2_ships) over time for each match."""
    matches = tick_df['match_filename'].unique()
    n_matches = len(matches)
    # Create a figure with subplots (arrange in a grid)
    cols = 2
    rows = (n_matches + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(14, 5 * rows))
    axes = axes.flatten() if n_matches > 1 else [axes]
    for idx, match in enumerate(matches):
        match_data = tick_df[tick_df['match_filename'] == match].sort_values('time')
        advantage = match_data['bot1_ships'] - match_data['bot2_ships']
        axes[idx].plot(match_data['time'], advantage, marker='.', linestyle='-', linewidth=0.8, markersize=2)
        axes[idx].axhline(y=0, color='gray', linestyle='--', linewidth=0.8)
        axes[idx].set_title(f'{match[:30]}...', fontsize=9)
        axes[idx].set_xlabel('Time (s)')
        axes[idx].set_ylabel('Ship Advantage (Bot1 - Bot2)')
    # Hide unused subplots
    for idx in range(len(matches), len(axes)):
        axes[idx].axis('off')
    plt.suptitle('Ship Advantage Over Time (per match)', fontsize=14, y=1.02)
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'ship_advantage_over_time.png'), dpi=150)
    plt.close()


def plot_ship_and_planet_evolution(tick_df, match_df, output_dir):
    """
    For each match, create a figure with two subplots:
    - Ship counts over time
    - Planet counts over time
    """
    matches = tick_df['match_filename'].unique()
    for match in matches:
        match_data = tick_df[tick_df['match_filename'] == match].sort_values('time')
        # Extract bot names from match summary
        match_info = match_df[match_df['filename'] == match].iloc[0]
        bot1, bot2 = match_info['bot1'], match_info['bot2']
        winner = match_info['winner']

        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8))
        # Ship counts
        ax1.plot(match_data['time'], match_data['bot1_ships'], label=f'{bot1} (ships)', color='blue', linewidth=2)
        ax1.plot(match_data['time'], match_data['bot2_ships'], label=f'{bot2} (ships)', color='orange', linewidth=2)
        ax1.set_ylabel('Ship Count')
        ax1.set_title(f'Match: {match}\nWinner: {winner}', fontsize=10)
        ax1.legend()
        ax1.grid(True, alpha=0.3)
        # Planet counts
        ax2.plot(match_data['time'], match_data['bot1_planets'], label=f'{bot1} (planets)', color='blue', linestyle='--')
        ax2.plot(match_data['time'], match_data['bot2_planets'], label=f'{bot2} (planets)', color='orange', linestyle='--')
        ax2.set_xlabel('Time (s)')
        ax2.set_ylabel('Planet Count')
        ax2.legend()
        ax2.grid(True, alpha=0.3)
        plt.tight_layout()
        # Create a safe filename
        safe_name = match.replace('.log', '').replace('/', '_').replace('\\', '_')
        plt.savefig(os.path.join(output_dir, f'{safe_name}_evolution.png'), dpi=150)
        plt.close()
        print(f"  Saved plot for {match}")


def plot_final_ships_boxplot(match_df, output_dir):
    """Boxplot comparing final ship counts of bot1 and bot2 across matches."""
    data = [match_df['final_ships_bot1'].dropna(), match_df['final_ships_bot2'].dropna()]
    labels = [match_df['bot1'].iloc[0] if not match_df.empty else 'Bot1', 
              match_df['bot2'].iloc[0] if not match_df.empty else 'Bot2']
    plt.figure()
    bp = plt.boxplot(data, labels=labels, patch_artist=True, 
                     boxprops=dict(facecolor='lightblue'), medianprops=dict(color='red'))
    plt.title('Distribution of Final Ship Counts (All Matches)', fontsize=14)
    plt.ylabel('Final Ships')
    plt.grid(axis='y', alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(output_dir, 'final_ships_boxplot.png'), dpi=150)
    plt.close()


def main():
    parser = argparse.ArgumentParser(description='Generate plots from Galcon log CSVs.')
    parser.add_argument('--match-summary', default='match_summary.csv',
                        help='Path to match_summary.csv (default: match_summary.csv)')
    parser.add_argument('--tick-data', default='tick_data.csv',
                        help='Path to tick_data.csv (default: tick_data.csv)')
    parser.add_argument('--output-dir', default='plots',
                        help='Directory to save plots (default: ./plots)')
    args = parser.parse_args()

    # Create output directory
    os.makedirs(args.output_dir, exist_ok=True)

    # Load data
    print("Loading data...")
    match_df, tick_df = load_data(args.match_summary, args.tick_data)
    print(f"Loaded {len(match_df)} matches and {len(tick_df)} tick records.")

    # Generate plots
    print("Generating win counts plot...")
    plot_win_counts(match_df, args.output_dir)

    print("Generating ship advantage over time plots...")
    plot_ship_advantage_over_time(tick_df, args.output_dir)

    print("Generating per‑match evolution plots...")
    plot_ship_and_planet_evolution(tick_df, match_df, args.output_dir)

    print("Generating final ships boxplot...")
    plot_final_ships_boxplot(match_df, args.output_dir)

    print(f"All plots saved to '{args.output_dir}'")


if __name__ == '__main__':
    main()
