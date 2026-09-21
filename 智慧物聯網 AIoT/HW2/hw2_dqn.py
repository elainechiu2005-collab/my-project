import numpy as np
import random
import os
import time
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.gridspec as gridspec
from collections import deque

import torch
import torch.nn as nn
import torch.optim as optim
import torch.nn.functional as F

#  1.  Smart Greenhouse Environment  (identical to HW1 for fair compare)
class SmartGreenhouseEnv:
    ACTION_NAMES = {
        0: "do_nothing",    1: "pump_on",       2: "pump_off",
        3: "heater_on",     4: "heater_off",
        5: "curtains_open", 6: "curtains_close",
    }
    STATE_LABELS = {
        "moisture":    ["Dry",  "Optimal", "Wet"],
        "temperature": ["Low",  "Optimal", "High"],
        "sunlight":    ["Low",  "Medium",  "High"],
    }

    def __init__(self, max_steps: int = 24):
        self.state_space_shape = (3, 3, 3)
        self.action_space_n    = 7
        self.max_steps         = max_steps
        self.reset()

    def reset(self):
        self.state      = [random.randint(0, 2) for _ in range(3)]
        self.step_count = 0
        return tuple(self.state)

    def _transit(self, value: int, delta: int,
                 p_down: float = 0.15, p_up: float = 0.10) -> int:
        if delta > 0:
            value += 1 if random.random() < 0.75 else 0
        elif delta < 0:
            value -= 1 if random.random() < 0.75 else 0
        else:
            r = random.random()
            if   r < p_down:          value -= 1
            elif r < p_down + p_up:   value += 1
        return max(0, min(2, value))

    def step(self, action: int):
        moisture, temp, sun = self.state
        pump_on        = (action == 1)
        pump_off       = (action == 2)
        heater_on      = (action == 3)
        heater_off     = (action == 4)
        curtains_open  = (action == 5)
        curtains_close = (action == 6)

        if pump_on:    moisture = self._transit(moisture, +1)
        elif pump_off: moisture = self._transit(moisture, 0, p_down=0.25, p_up=0.05)
        else:          moisture = self._transit(moisture, 0, p_down=0.20, p_up=0.05)

        if heater_on:    temp = self._transit(temp, +1)
        elif heater_off: temp = self._transit(temp, 0, p_down=0.25, p_up=0.05)
        else:            temp = self._transit(temp, 0, p_down=0.15, p_up=0.10)

        if curtains_open:  sun = self._transit(sun, +1, p_down=0.05, p_up=0.70)
        elif curtains_close: sun = self._transit(sun, -1, p_down=0.70, p_up=0.05)
        else:              sun = self._transit(sun, 0, p_down=0.20, p_up=0.20)

        self.state      = [moisture, temp, sun]
        self.step_count += 1

        # Reward Function R(s, a) 
        reward  = 10 if moisture == 1 else (-8  if moisture == 0 else -3)
        reward += 12 if temp     == 1 else (-10 if temp     == 0 else -6)
        reward +=  6 if sun      == 1 else (-2  if sun      == 0 else -2)

        if pump_on:                         reward -= 2   # water cost
        if heater_on:                       reward -= 5   # electricity peak cost
        if curtains_open or curtains_close: reward -= 1   # mechanical wear
        if moisture == 1 and temp == 1:     reward += 3   # synergy bonus
        if moisture == 0 or temp == 0:      reward -= 4   # critical-stress penalty

        done = self.step_count >= self.max_steps
        return tuple(self.state), reward, done


#  2.  State Encoding — one-hot for neural network input
def encode_state(state: tuple) -> np.ndarray:
    enc = np.zeros(9, dtype=np.float32)
    enc[state[0]]     = 1.0   # moisture (indices 0–2)
    enc[3 + state[1]] = 1.0   # temperature (indices 3–5)
    enc[6 + state[2]] = 1.0   # sunlight (indices 6–8)
    return enc



#  3.  DQN Neural Network
class DQNNetwork(nn.Module):
    def __init__(self, input_size: int = 9,
                 hidden_size: int = 64, output_size: int = 7):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(input_size, hidden_size),
            nn.ReLU(),
            nn.Linear(hidden_size, hidden_size),
            nn.ReLU(),
            nn.Linear(hidden_size, output_size),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)

#  4.  Experience Replay Buffer
class ReplayBuffer:
    def __init__(self, capacity: int = 10_000):
        self.buf = deque(maxlen=capacity)

    def push(self, state, action, reward, next_state, done):
        self.buf.append((state, action, reward, next_state, float(done)))

    def sample(self, batch_size: int):
        batch       = random.sample(self.buf, batch_size)
        s, a, r, ns, d = zip(*batch)
        return (np.array(s,  dtype=np.float32),
                np.array(a,  dtype=np.int64),
                np.array(r,  dtype=np.float32),
                np.array(ns, dtype=np.float32),
                np.array(d,  dtype=np.float32))

    def __len__(self):
        return len(self.buf)


#  5.  DQN Agent
class DQNAgent:
    def __init__(self,
                 state_size:        int   = 9,
                 action_size:       int   = 7,
                 hidden_size:       int   = 64,
                 lr:                float = 1e-3,
                 gamma:             float = 0.9,
                 epsilon:           float = 1.0,
                 epsilon_decay:     float = 0.9995,
                 epsilon_min:       float = 0.01,
                 batch_size:        int   = 64,
                 buffer_capacity:   int   = 10_000,
                 target_update_freq: int  = 200):

        self.action_size        = action_size
        self.gamma              = gamma
        self.epsilon            = epsilon
        self.epsilon_decay      = epsilon_decay
        self.epsilon_min        = epsilon_min
        self.batch_size         = batch_size
        self.target_update_freq = target_update_freq
        self.steps_done         = 0

        # Device selection: Apple MPS > CUDA > CPU
        if torch.backends.mps.is_available():
            self.device = torch.device("mps")
        elif torch.cuda.is_available():
            self.device = torch.device("cuda")
        else:
            self.device = torch.device("cpu")

        # Policy network (updated every step)
        self.policy_net = DQNNetwork(state_size, hidden_size, action_size).to(self.device)
        # Target network (frozen; periodically synced)
        self.target_net = DQNNetwork(state_size, hidden_size, action_size).to(self.device)
        self.target_net.load_state_dict(self.policy_net.state_dict())
        self.target_net.eval()

        self.optimizer    = optim.Adam(self.policy_net.parameters(), lr=lr)
        self.replay_buffer = ReplayBuffer(buffer_capacity)

        # Training history
        self.episode_rewards : list[float] = []
        self.episode_losses  : list[float] = []
        self.epsilon_history : list[float] = []

    def select_action(self, state: np.ndarray) -> int:
        if random.random() < self.epsilon:
            return random.randint(0, self.action_size - 1)
        with torch.no_grad():
            s_t = torch.from_numpy(state).unsqueeze(0).to(self.device)
            return self.policy_net(s_t).argmax(dim=1).item()

    def optimize(self) -> float | None:
        if len(self.replay_buffer) < self.batch_size:
            return None

        s, a, r, ns, d = self.replay_buffer.sample(self.batch_size)

        s_t  = torch.from_numpy(s).to(self.device)
        a_t  = torch.from_numpy(a).unsqueeze(1).to(self.device)
        r_t  = torch.from_numpy(r).to(self.device)
        ns_t = torch.from_numpy(ns).to(self.device)
        d_t  = torch.from_numpy(d).to(self.device)

        # Q(s, a; θ)
        q_vals = self.policy_net(s_t).gather(1, a_t).squeeze(1)

        # y = r + γ · max_{a'} Q̂(s', a'; θ⁻)
        with torch.no_grad():
            next_q  = self.target_net(ns_t).max(1).values
            targets = r_t + self.gamma * next_q * (1.0 - d_t)

        loss = F.mse_loss(q_vals, targets)

        self.optimizer.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(self.policy_net.parameters(), 10.0)
        self.optimizer.step()

        # Periodically sync target network
        self.steps_done += 1
        if self.steps_done % self.target_update_freq == 0:
            self.target_net.load_state_dict(self.policy_net.state_dict())

        return loss.item()

    def train(self, env: SmartGreenhouseEnv, n_episodes: int = 8000) -> np.ndarray:
        print("=" * 58)
        print("  DQN Training  —  Smart Greenhouse Management System")
        print("=" * 58)
        print(f"  Episodes        : {n_episodes}")
        print(f"  Device          : {self.device}")
        print(f"  Batch size      : {self.batch_size}")
        print(f"  Replay capacity : {self.replay_buffer.buf.maxlen}")
        print(f"  Target update   : every {self.target_update_freq} steps")
        print(f"  γ (discount)    : {self.gamma}")
        print(f"  ε decay         : {self.epsilon} → {self.epsilon_min}")
        print("=" * 58)

        for ep in range(n_episodes):
            disc_state = env.reset()
            state      = encode_state(disc_state)
            total_r    = 0
            ep_losses  = []

            while True:
                action              = self.select_action(state)
                next_disc, r, done  = env.step(action)
                next_state          = encode_state(next_disc)

                self.replay_buffer.push(state, action, r, next_state, done)
                loss = self.optimize()
                if loss is not None:
                    ep_losses.append(loss)

                state   = next_state
                total_r += r
                if done:
                    break

            self.epsilon = max(self.epsilon_min, self.epsilon * self.epsilon_decay)
            self.episode_rewards.append(total_r)
            self.epsilon_history.append(self.epsilon)
            self.episode_losses.append(np.mean(ep_losses) if ep_losses else 0.0)

            if (ep + 1) % 1000 == 0:
                avg     = np.mean(self.episode_rewards[-1000:])
                avg_lss = np.mean(self.episode_losses[-1000:])
                print(f"  Episode {ep+1:5d}/{n_episodes} | ε={self.epsilon:.4f} | "
                      f"Reward={total_r:6d} | Avg(1000)={avg:6.1f} | Loss={avg_lss:.5f}")

        print("=" * 58)
        print("  DQN Training Completed!")
        return np.array(self.episode_rewards)

    def evaluate(self, env: SmartGreenhouseEnv, n_episodes: int = 200) -> np.ndarray:
        rewards = []
        for _ in range(n_episodes):
            disc  = env.reset()
            state = encode_state(disc)
            ep_r  = 0
            while True:
                with torch.no_grad():
                    s_t = torch.from_numpy(state).unsqueeze(0).to(self.device)
                    act = self.policy_net(s_t).argmax(dim=1).item()
                next_disc, r, done = env.step(act)
                state = encode_state(next_disc)
                ep_r += r
                if done:
                    break
            rewards.append(ep_r)
        return np.array(rewards)

    def get_q_table(self) -> np.ndarray:
        qt = np.zeros((3, 3, 3, self.action_size))
        for m in range(3):
            for t in range(3):
                for s in range(3):
                    enc = encode_state((m, t, s))
                    s_t = torch.from_numpy(enc).unsqueeze(0).to(self.device)
                    with torch.no_grad():
                        qt[m, t, s] = self.policy_net(s_t).cpu().numpy()[0]
        return qt

    def print_policy(self):
        m_lbl = SmartGreenhouseEnv.STATE_LABELS["moisture"]
        t_lbl = SmartGreenhouseEnv.STATE_LABELS["temperature"]
        s_lbl = SmartGreenhouseEnv.STATE_LABELS["sunlight"]
        qt    = self.get_q_table()
        print("\n  DQN Greedy Policy:")
        print(f"  {'Moisture':20s} {'Temperature':15s} {'Sunlight':15s} -> Action")
        print("  " + "-" * 65)
        for m in range(3):
            for t in range(3):
                for s in range(3):
                    a = int(np.argmax(qt[m, t, s]))
                    print(f"  {m_lbl[m]:20s} {t_lbl[t]:15s} {s_lbl[s]:15s} -> "
                          f"{SmartGreenhouseEnv.ACTION_NAMES[a]}")


#  6.  Plotting Utilities
def moving_average(x: np.ndarray, w: int = 200) -> np.ndarray:
    return np.convolve(x, np.ones(w) / w, mode='valid')

def save_fig(fig, path: str):
    fig.savefig(path, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f"  [Saved] {path}")

ACTION_LABELS_SHORT = [
    'Nothing', 'Pump ON', 'Pump OFF',
    'Heat ON', 'Heat OFF', 'Curtain\nOpen', 'Curtain\nClose'
]
QL_COLOR  = '#1A73E8'   # Blue
DQN_COLOR = '#D93025'   # Red


def plot_training_comparison(ql_rewards: np.ndarray, dqn_rewards: np.ndarray,
                              out_dir: str = "plots"):
    MA_W = 200
    fig, axes = plt.subplots(2, 1, figsize=(12, 8), sharex=True)
    fig.suptitle('Training Reward Trend: Q-Learning vs DQN', fontsize=15, fontweight='bold')

    for ax, rewards, color, label in zip(
            axes,
            [ql_rewards, dqn_rewards],
            [QL_COLOR,   DQN_COLOR],
            ['Q-Learning', 'DQN']):
        eps = range(1, len(rewards) + 1)
        ax.plot(eps, rewards, color=color, alpha=0.25, linewidth=0.6, label='Per-episode reward')
        if len(rewards) >= MA_W:
            ma = moving_average(rewards, MA_W)
            ax.plot(range(MA_W, len(rewards) + 1), ma,
                    color=color, linewidth=2.2, label=f'MA-{MA_W}')
        final_avg = np.mean(rewards[-500:])
        ax.axhline(final_avg, color='black', linestyle='--', linewidth=1.2,
                   label=f'Last-500 avg: {final_avg:.1f}')
        ax.set_title(label, fontsize=12, fontweight='bold', color=color)
        ax.set_ylabel('Cumulative Reward', fontsize=11)
        ax.legend(fontsize=9)
        ax.grid(True, alpha=0.3)

    axes[-1].set_xlabel('Episode', fontsize=11)
    plt.tight_layout()
    save_fig(fig, os.path.join(out_dir, 'hw2_training_comparison.png'))


def plot_smoothed_overlay(ql_rewards: np.ndarray, dqn_rewards: np.ndarray,
                           out_dir: str = "plots"):
    MA_W = 200
    fig, ax = plt.subplots(figsize=(12, 5))

    ql_ma  = moving_average(ql_rewards,  MA_W)
    dqn_ma = moving_average(dqn_rewards, MA_W)
    x      = range(MA_W, len(ql_rewards) + 1)

    ax.plot(x, ql_ma,  color=QL_COLOR,  linewidth=2.2, label=f'Q-Learning (MA-{MA_W})')
    ax.plot(x, dqn_ma, color=DQN_COLOR, linewidth=2.2, label=f'DQN (MA-{MA_W})',
            linestyle='--')

    ax.fill_between(x, ql_ma,  alpha=0.12, color=QL_COLOR)
    ax.fill_between(x, dqn_ma, alpha=0.12, color=DQN_COLOR)

    ax.axhline(np.mean(ql_rewards[-500:]),  color=QL_COLOR,  linestyle=':',
               linewidth=1.5, alpha=0.7)
    ax.axhline(np.mean(dqn_rewards[-500:]), color=DQN_COLOR, linestyle=':',
               linewidth=1.5, alpha=0.7)

    ax.set_xlabel('Episode', fontsize=12)
    ax.set_ylabel('Moving-Average Reward', fontsize=12)
    ax.set_title('Convergence Comparison: Q-Learning vs DQN', fontsize=14, fontweight='bold')
    ax.legend(fontsize=11)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    save_fig(fig, os.path.join(out_dir, 'hw2_convergence_overlay.png'))


def plot_dqn_loss(dqn_losses: np.ndarray, out_dir: str = "plots"):
    fig, ax = plt.subplots(figsize=(11, 4))
    ax.plot(range(1, len(dqn_losses) + 1), dqn_losses,
            color=DQN_COLOR, alpha=0.35, linewidth=0.7, label='MSE Loss (per episode)')
    if len(dqn_losses) >= 200:
        lma = moving_average(np.array(dqn_losses), 200)
        ax.plot(range(200, len(dqn_losses) + 1), lma,
                color=DQN_COLOR, linewidth=2.2, label='MA-200')
    ax.set_xlabel('Episode', fontsize=12)
    ax.set_ylabel('MSE Loss', fontsize=12)
    ax.set_title('DQN Training Loss (Bellman Error)', fontsize=14, fontweight='bold')
    ax.legend(fontsize=10)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    save_fig(fig, os.path.join(out_dir, 'hw2_dqn_loss.png'))


def plot_test_comparison(ql_test: np.ndarray, dqn_test: np.ndarray,
                          out_dir: str = "plots"):
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    fig.suptitle('Test Policy Evaluation: Q-Learning vs DQN', fontsize=14, fontweight='bold')

    # Histograms
    for ax, rewards, color, label in zip(
            axes[:2],
            [ql_test, dqn_test],
            [QL_COLOR, DQN_COLOR],
            ['Q-Learning', 'DQN']):
        ax.hist(rewards, bins=20, color=color, edgecolor='white', alpha=0.8)
        ax.axvline(np.mean(rewards), color='black', linestyle='--', linewidth=2,
                   label=f'Mean: {np.mean(rewards):.1f}')
        ax.axvline(np.median(rewards), color='gray', linestyle=':', linewidth=2,
                   label=f'Median: {np.median(rewards):.1f}')
        ax.set_title(label, fontsize=12, color=color, fontweight='bold')
        ax.set_xlabel('Cumulative Reward', fontsize=11)
        ax.set_ylabel('Frequency', fontsize=11)
        ax.legend(fontsize=9)
        ax.grid(True, alpha=0.3)

    # Box plot
    bp = axes[2].boxplot([ql_test, dqn_test],
                          labels=['Q-Learning', 'DQN'],
                          patch_artist=True,
                          medianprops={'color': 'black', 'linewidth': 2.5},
                          whiskerprops={'linewidth': 1.5},
                          capprops={'linewidth': 1.5})
    bp['boxes'][0].set_facecolor(QL_COLOR)
    bp['boxes'][1].set_facecolor(DQN_COLOR)
    for box in bp['boxes']:
        box.set_alpha(0.75)
    axes[2].set_title('Box-plot Comparison', fontsize=12, fontweight='bold')
    axes[2].set_ylabel('Cumulative Reward', fontsize=11)
    axes[2].grid(True, alpha=0.3, axis='y')

    plt.tight_layout()
    save_fig(fig, os.path.join(out_dir, 'hw2_test_comparison.png'))


def plot_policy_heatmaps(ql_qtable: np.ndarray, dqn_qtable: np.ndarray,
                          out_dir: str = "plots"):
    cmap      = plt.get_cmap('tab10', 7)
    sun_names = ['Sunlight = Low', 'Sunlight = Medium', 'Sunlight = High']

    fig, axes = plt.subplots(2, 3, figsize=(15, 9))
    fig.suptitle('Optimal Policy Heatmaps — Q-Learning (top) vs DQN (bottom)',
                 fontsize=14, fontweight='bold')

    for row_idx, (qtable, method) in enumerate([(ql_qtable, 'Q-Learning'), (dqn_qtable, 'DQN')]):
        for s_idx in range(3):
            ax = axes[row_idx, s_idx]
            matrix = np.array([[int(np.argmax(qtable[m, t, s_idx]))
                                 for t in range(3)] for m in range(3)])
            ax.imshow(matrix, cmap=cmap, vmin=0, vmax=6, aspect='auto')
            ax.set_xticks([0, 1, 2])
            ax.set_yticks([0, 1, 2])
            ax.set_xticklabels(['Low', 'Opt', 'High'], fontsize=10)
            ax.set_yticklabels(['Dry', 'Opt', 'Wet'],  fontsize=10)
            ax.set_xlabel('Temperature', fontsize=10)
            ax.set_ylabel('Moisture',    fontsize=10)
            ax.set_title(f'{method}\n{sun_names[s_idx]}', fontsize=10, fontweight='bold',
                         color=QL_COLOR if method == 'Q-Learning' else DQN_COLOR)
            for m in range(3):
                for t in range(3):
                    ax.text(t, m, ACTION_LABELS_SHORT[matrix[m, t]],
                            ha='center', va='center', fontsize=7,
                            color='white' if matrix[m, t] in [1, 3] else 'black',
                            fontweight='bold')

    patches = [mpatches.Patch(color=cmap(i), label=f'{i}: {ACTION_LABELS_SHORT[i]}')
               for i in range(7)]
    fig.legend(handles=patches, loc='lower center', ncol=7, fontsize=9,
               bbox_to_anchor=(0.5, -0.02))
    plt.tight_layout(rect=[0, 0.04, 1, 1])
    save_fig(fig, os.path.join(out_dir, 'hw2_policy_heatmap.png'))


def plot_summary_bar(ql_rewards, dqn_rewards, ql_test, dqn_test, out_dir="plots"):
    fig, axes = plt.subplots(1, 2, figsize=(13, 5))
    fig.suptitle('Summary Statistics: Q-Learning vs DQN', fontsize=14, fontweight='bold')

    metrics_train = ['Final\nAvg Reward\n(last 500)', 'Best\nReward', 'Worst\nReward']
    ql_tr  = [np.mean(ql_rewards[-500:]),  np.max(ql_rewards),  np.min(ql_rewards[-500:])]
    dqn_tr = [np.mean(dqn_rewards[-500:]), np.max(dqn_rewards), np.min(dqn_rewards[-500:])]

    x  = np.arange(len(metrics_train))
    w  = 0.35
    b1 = axes[0].bar(x - w/2, ql_tr,  w, label='Q-Learning', color=QL_COLOR,  alpha=0.85)
    b2 = axes[0].bar(x + w/2, dqn_tr, w, label='DQN',        color=DQN_COLOR, alpha=0.85)
    for bars in (b1, b2):
        for bar in bars:
            h = bar.get_height()
            axes[0].annotate(f'{h:.0f}',
                             xy=(bar.get_x() + bar.get_width() / 2, h),
                             xytext=(0, 3), textcoords='offset points',
                             ha='center', va='bottom', fontsize=9)
    axes[0].set_xticks(x); axes[0].set_xticklabels(metrics_train, fontsize=10)
    axes[0].set_title('Training Phase', fontweight='bold', fontsize=12)
    axes[0].set_ylabel('Cumulative Reward'); axes[0].legend(); axes[0].grid(True, alpha=0.3, axis='y')

    metrics_test = ['Test Mean', 'Test Median', 'Test Std']
    ql_ts  = [np.mean(ql_test),   np.median(ql_test),   np.std(ql_test)]
    dqn_ts = [np.mean(dqn_test),  np.median(dqn_test),  np.std(dqn_test)]

    b3 = axes[1].bar(x - w/2, ql_ts,  w, label='Q-Learning', color=QL_COLOR,  alpha=0.85)
    b4 = axes[1].bar(x + w/2, dqn_ts, w, label='DQN',        color=DQN_COLOR, alpha=0.85)
    for bars in (b3, b4):
        for bar in bars:
            h = bar.get_height()
            axes[1].annotate(f'{h:.1f}',
                             xy=(bar.get_x() + bar.get_width() / 2, h),
                             xytext=(0, 3), textcoords='offset points',
                             ha='center', va='bottom', fontsize=9)
    axes[1].set_xticks(x); axes[1].set_xticklabels(metrics_test, fontsize=10)
    axes[1].set_title('Test Phase (200 episodes)', fontweight='bold', fontsize=12)
    axes[1].set_ylabel('Reward'); axes[1].legend(); axes[1].grid(True, alpha=0.3, axis='y')

    plt.tight_layout()
    save_fig(fig, os.path.join(out_dir, 'hw2_summary_bar.png'))


def generate_all_plots(ql_rewards, dqn_rewards, dqn_losses, ql_test, dqn_test,
                        ql_qtable, dqn_qtable, out_dir="plots"):
    os.makedirs(out_dir, exist_ok=True)
    print("\n  Generating comparison plots …")
    plot_training_comparison(ql_rewards, dqn_rewards, out_dir)
    plot_smoothed_overlay(ql_rewards, dqn_rewards, out_dir)
    plot_dqn_loss(np.array(dqn_losses), out_dir)
    plot_test_comparison(ql_test, dqn_test, out_dir)
    plot_policy_heatmaps(ql_qtable, dqn_qtable, out_dir)
    plot_summary_bar(ql_rewards, dqn_rewards, ql_test, dqn_test, out_dir)
    print(f"\n  All HW2 plots saved to: {out_dir}/")


if __name__ == "__main__":
    EPISODES       = 8_000
    GAMMA          = 0.9
    EPSILON_START  = 1.0
    EPSILON_DECAY  = 0.9995  
    EPSILON_MIN    = 0.01
    LR             = 1e-3
    BATCH_SIZE     = 64
    BUFFER_CAP     = 10_000
    TARGET_UPDATE  = 200
    TEST_EPISODES  = 200
    SEED           = 42
    OUT_DIR        = "plots"

    random.seed(SEED)
    np.random.seed(SEED)
    torch.manual_seed(SEED)

    env = SmartGreenhouseEnv()

    print("  Loading Q-Learning results from HW1 …")
    ql_rewards = np.load(os.path.join(OUT_DIR, "ql_ep_rewards.npy"))
    ql_test    = np.load(os.path.join(OUT_DIR, "ql_test_rewards.npy"))
    ql_qtable  = np.load(os.path.join(OUT_DIR, "q_table.npy"))
    print(f"  Q-Learning: {len(ql_rewards)} episodes loaded.")
    print(f"  Q-Learning test avg: {np.mean(ql_test):.2f} ± {np.std(ql_test):.2f}")

    agent = DQNAgent(
        state_size        = 9,
        action_size       = 7,
        hidden_size       = 64,
        lr                = LR,
        gamma             = GAMMA,
        epsilon           = EPSILON_START,
        epsilon_decay     = EPSILON_DECAY,
        epsilon_min       = EPSILON_MIN,
        batch_size        = BATCH_SIZE,
        buffer_capacity   = BUFFER_CAP,
        target_update_freq= TARGET_UPDATE,
    )

    t0 = time.time()
    dqn_rewards = agent.train(env, n_episodes=EPISODES)
    dqn_train_time = time.time() - t0

    print("\n  [Test Phase] Evaluating DQN greedy policy …")
    random.seed(0); np.random.seed(0)
    dqn_test = agent.evaluate(env, n_episodes=TEST_EPISODES)
    print(f"  Test Episodes : {TEST_EPISODES}")
    print(f"  Average Reward: {np.mean(dqn_test):.2f} ± {np.std(dqn_test):.2f}")
    print(f"  Max Reward    : {np.max(dqn_test):.0f}")
    print(f"  Min Reward    : {np.min(dqn_test):.0f}")

    agent.print_policy()

    print("\n" + "=" * 58)
    print("  FINAL COMPARISON SUMMARY")
    print("=" * 58)
    print(f"  {'Metric':<35s} {'Q-Learning':>10s} {'DQN':>10s}")
    print("  " + "-" * 55)
    print(f"  {'Training Episodes':<35s} {len(ql_rewards):>10d} {len(dqn_rewards):>10d}")
    print(f"  {'Train Avg Reward (last 500)':<35s} {np.mean(ql_rewards[-500:]):>10.1f} {np.mean(dqn_rewards[-500:]):>10.1f}")
    print(f"  {'Train Best Reward':<35s} {np.max(ql_rewards):>10d} {np.max(dqn_rewards):>10d}")
    print(f"  {'Test Avg Reward':<35s} {np.mean(ql_test):>10.1f} {np.mean(dqn_test):>10.1f}")
    print(f"  {'Test Std Dev':<35s} {np.std(ql_test):>10.2f} {np.std(dqn_test):>10.2f}")
    print(f"  {'Test Median Reward':<35s} {np.median(ql_test):>10.1f} {np.median(dqn_test):>10.1f}")
    print(f"  {'DQN Training Time (s)':<35s} {'—':>10s} {dqn_train_time:>10.1f}")
    print("=" * 58)

    dqn_qtable = agent.get_q_table()
    np.save(os.path.join(OUT_DIR, "dqn_ep_rewards.npy"),  dqn_rewards)
    np.save(os.path.join(OUT_DIR, "dqn_test_rewards.npy"), dqn_test)
    np.save(os.path.join(OUT_DIR, "dqn_losses.npy"),       np.array(agent.episode_losses))
    np.save(os.path.join(OUT_DIR, "dqn_q_table.npy"),      dqn_qtable)

    generate_all_plots(
        ql_rewards  = ql_rewards,
        dqn_rewards = dqn_rewards,
        dqn_losses  = agent.episode_losses,
        ql_test     = ql_test,
        dqn_test    = dqn_test,
        ql_qtable   = ql_qtable,
        dqn_qtable  = dqn_qtable,
        out_dir     = OUT_DIR,
    )

    print("\n  Done!  Check the plots/ folder for all generated figures.")
