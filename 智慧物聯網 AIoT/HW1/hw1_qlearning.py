import numpy as np
import random
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import os

#  Environment
class SmartGreenhouseEnv:
    """
    Smart Greenhouse MDP Environment
    """
    ACTION_NAMES = {
        0: "do_nothing", 1: "pump_on", 2: "pump_off",
        3: "heater_on", 4: "heater_off", 5: "curtains_open", 6: "curtains_close",
    }
    STATE_LABELS = {
        "moisture":    ["Dry", "Optimal", "Wet"],
        "temperature": ["Low", "Optimal", "High"],
        "sunlight":    ["Low", "Medium",  "High"],
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

        if pump_on: moisture = self._transit(moisture, +1)
        elif pump_off: moisture = self._transit(moisture, 0, p_down=0.25, p_up=0.05)
        else: moisture = self._transit(moisture, 0, p_down=0.20, p_up=0.05)

        if heater_on: temp = self._transit(temp, +1)
        elif heater_off: temp = self._transit(temp, 0, p_down=0.25, p_up=0.05)
        else: temp = self._transit(temp, 0, p_down=0.15, p_up=0.10)

        if curtains_open: sun = self._transit(sun, +1, p_down=0.05, p_up=0.70)
        elif curtains_close: sun = self._transit(sun, -1, p_down=0.70, p_up=0.05)
        else: sun = self._transit(sun, 0, p_down=0.20, p_up=0.20)

        self.state      = [moisture, temp, sun]
        self.step_count += 1
        reward = 0

        reward += 10 if moisture == 1 else (-8 if moisture == 0 else -3)
        reward += 12 if temp     == 1 else (-10 if temp     == 0 else -6)
        reward +=  6 if sun      == 1 else (-2  if sun      == 0 else -2)

        if pump_on: reward -= 2
        if heater_on: reward -= 5
        if curtains_open or curtains_close: reward -= 1
        if moisture == 1 and temp == 1: reward += 3
        if moisture == 0 or temp == 0:  reward -= 4

        done = self.step_count >= self.max_steps
        return tuple(self.state), reward, done

    @classmethod
    def action_name(cls, action: int) -> str:
        return cls.ACTION_NAMES[action]


#  Q-Learning Training
def train_q_learning(episodes: int = 8000, alpha: float = 0.1, gamma: float = 0.9,
                     epsilon_start: float = 1.0, epsilon_decay: float = 0.9995,
                     epsilon_min: float = 0.01, seed: int = 42):
    random.seed(seed)
    np.random.seed(seed)
    env     = SmartGreenhouseEnv()
    q_table = np.zeros(env.state_space_shape + (env.action_space_n,))
    epsilon = epsilon_start
    episode_rewards  = []
    epsilon_history  = []

    print("=" * 55)
    print("  Q-Learning Training Started")
    print("=" * 55)
    print(f"  Episodes     : {episodes}")
    print(f"  Alpha (lr)   : {alpha}")
    print(f"  Gamma        : {gamma}")
    print(f"  Epsilon start: {epsilon_start}  decay: {epsilon_decay}  min: {epsilon_min}")
    print("=" * 55)

    for ep in range(episodes):
        state = env.reset()
        total_reward = 0
        while True:
            if random.random() < epsilon: action = random.randint(0, env.action_space_n - 1)
            else: action = int(np.argmax(q_table[state]))
            next_state, reward, done = env.step(action)
            total_reward += reward
            td_target = reward + gamma * np.max(q_table[next_state])
            q_table[state][action] += alpha * (td_target - q_table[state][action])
            state = next_state
            if done: break
        
        epsilon = max(epsilon_min, epsilon * epsilon_decay)
        episode_rewards.append(total_reward)
        epsilon_history.append(epsilon)

        if (ep + 1) % 1000 == 0:
            avg = np.mean(episode_rewards[-1000:])
            print(f"  Episode {ep+1:5d}/{episodes} | ε={epsilon:.4f} | "
                  f"Reward={total_reward:5d} | Avg(last 1000)={avg:6.1f}")

    print("=" * 55)
    print("  Q-Learning Training Completed!")
    return q_table, np.array(episode_rewards), np.array(epsilon_history)



#  Evaluation / Test Phase
def evaluate_policy(q_table, episodes: int = 200, seed: int = 0):
    random.seed(seed)
    env = SmartGreenhouseEnv()
    rewards = []
    for _ in range(episodes):
        state = env.reset()
        ep_reward = 0
        while True:
            action = int(np.argmax(q_table[state]))
            state, r, done = env.step(action)
            ep_reward += r
            if done: break
        rewards.append(ep_reward)
    return np.array(rewards)

def run_one_episode_trace(q_table, seed: int = 7):
    random.seed(seed)
    env = SmartGreenhouseEnv()
    state = env.reset()
    moistures, temps, suns, actions, rewards = [], [], [], [], []
    while True:
        action = int(np.argmax(q_table[state]))
        next_state, r, done = env.step(action)
        moistures.append(state[0])
        temps.append(state[1])
        suns.append(state[2])
        actions.append(action)
        rewards.append(r)
        state = next_state
        if done: break
    return moistures, temps, suns, actions, rewards

def print_policy(q_table):
    m_lbl = SmartGreenhouseEnv.STATE_LABELS["moisture"]
    t_lbl = SmartGreenhouseEnv.STATE_LABELS["temperature"]
    s_lbl = SmartGreenhouseEnv.STATE_LABELS["sunlight"]
    print("\n  Learned Greedy Policy:")
    print("  {:20s} {:15s} {:15s} -> Action".format("Moisture", "Temperature", "Sunlight"))
    print("  " + "-" * 65)
    for m in range(3):
        for t in range(3):
            for s in range(3):
                a = int(np.argmax(q_table[m, t, s]))
                print(f"  {m_lbl[m]:20s} {t_lbl[t]:15s} {s_lbl[s]:15s} -> "
                      f"{SmartGreenhouseEnv.action_name(a)}")


#  Plot Helpers
def moving_average(x, w=200):
    return np.convolve(x, np.ones(w) / w, mode='valid')

def save_fig(fig, path: str):
    fig.savefig(path, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f"  [Saved] {path}")


def generate_plots(episode_rewards, epsilon_history, test_rewards,
                   moistures, temps, suns, actions, rewards,
                   q_table, out_dir: str = "plots"):
    os.makedirs(out_dir, exist_ok=True)
    ma_w = 200

    # ── Plot 1: Training Reward Curve ────────────────
    fig, ax = plt.subplots(figsize=(10, 4))
    eps = range(1, len(episode_rewards) + 1)
    ax.plot(eps, episode_rewards, color='#A8C7FA', alpha=0.4, linewidth=0.7, label='Reward per Episode')
    if len(episode_rewards) >= ma_w:
        ma = moving_average(episode_rewards, ma_w)
        ax.plot(range(ma_w, len(episode_rewards) + 1), ma,
                color='#1A73E8', linewidth=2, label=f'Moving Average (Window={ma_w})')
    ax.axhline(np.mean(episode_rewards[-500:]), color='red', linestyle='--',
               linewidth=1.2, label=f'Last 500 Episodes Avg: {np.mean(episode_rewards[-500:]):.1f}')
    ax.set_xlabel('Episode', fontsize=12)
    ax.set_ylabel('Total Reward', fontsize=12)
    ax.set_title('Q-Learning Training Curve', fontsize=14, fontweight='bold')
    ax.legend(fontsize=10)
    ax.grid(True, alpha=0.3)
    save_fig(fig, os.path.join(out_dir, 'hw1_training_curve.png'))

    # ── Plot 2: Epsilon Decay ─────────────────────────
    fig, ax = plt.subplots(figsize=(10, 3))
    ax.plot(range(1, len(epsilon_history) + 1), epsilon_history, color='#E37400', linewidth=1.5)
    ax.fill_between(range(1, len(epsilon_history) + 1), epsilon_history, alpha=0.2, color='#E37400')
    ax.set_xlabel('Episode', fontsize=12)
    ax.set_ylabel('Epsilon (ε)', fontsize=12)
    ax.set_title('Epsilon Decay Curve', fontsize=14, fontweight='bold')
    ax.grid(True, alpha=0.3)
    save_fig(fig, os.path.join(out_dir, 'hw1_epsilon_decay.png'))

    # ── Plot 3: Test Reward Histogram ─────────────────
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.hist(test_rewards, bins=20, color='#34A853', edgecolor='white', alpha=0.85)
    ax.axvline(np.mean(test_rewards), color='red', linestyle='--', linewidth=2,
               label=f'Mean: {np.mean(test_rewards):.1f}')
    ax.axvline(np.median(test_rewards), color='orange', linestyle=':', linewidth=2,
               label=f'Median: {np.median(test_rewards):.1f}')
    ax.set_xlabel('Test Cumulative Reward', fontsize=12)
    ax.set_ylabel('Frequency', fontsize=12)
    ax.set_title(f'Q-Learning Test Reward Distribution (N={len(test_rewards)} Episodes)', fontsize=14, fontweight='bold')
    ax.legend(fontsize=10)
    ax.grid(True, alpha=0.3)
    save_fig(fig, os.path.join(out_dir, 'hw1_test_distribution.png'))

    # ── Plot 4: State Trajectory ──────────────────────
    steps   = range(len(moistures))
    colors  = ['#1A73E8', '#E37400', '#34A853']
    labels  = ['Moisture', 'Temperature', 'Sunlight']
    markers = ['o', 's', '^']
    lv_lbls = [['Dry','Opt','Wet'], ['Low','Opt','High'], ['Low','Med','High']]

    fig, axes = plt.subplots(3, 1, figsize=(12, 8), sharex=True)
    for idx, (series, ax) in enumerate(zip([moistures, temps, suns], axes)):
        ax.step(steps, series, color=colors[idx], linewidth=2,
                marker=markers[idx], markersize=5, where='post', label=labels[idx])
        ax.set_yticks([0, 1, 2])
        ax.set_yticklabels(lv_lbls[idx], fontsize=10)
        ax.axhline(1, color='green', linestyle='--', alpha=0.4, linewidth=1)
        ax.set_ylabel(labels[idx], fontsize=10)
        ax.legend(loc='upper right', fontsize=9)
        ax.grid(True, alpha=0.3)
    axes[-1].set_xlabel('Time Step', fontsize=12)
    fig.suptitle('Test Phase: Single Episode State Trajectory', fontsize=14, fontweight='bold')
    plt.tight_layout()
    save_fig(fig, os.path.join(out_dir, 'hw1_state_trajectory.png'))

    # ── Plot 5: Policy Heatmap ────────────────────────
    action_labels_short = ['Nothing', 'Pump ON', 'Pump OFF',
                           'Heat ON', 'Heat OFF', 'Curtain Open', 'Curtain Close']
    cmap = plt.get_cmap('tab10', 7)

    fig, axes = plt.subplots(1, 3, figsize=(14, 4))
    sun_names = ['Sunlight=Low', 'Sunlight=Medium', 'Sunlight=High']

    for s_idx, ax in enumerate(axes):
        matrix = np.array([[int(np.argmax(q_table[m, t, s_idx]))
                            for t in range(3)] for m in range(3)])
        im = ax.imshow(matrix, cmap=cmap, vmin=0, vmax=6)
        ax.set_xticks([0, 1, 2])
        ax.set_yticks([0, 1, 2])
        ax.set_xticklabels(['Low', 'Opt', 'High'], fontsize=10)
        ax.set_yticklabels(['Dry', 'Opt', 'Wet'], fontsize=10)
        ax.set_xlabel('Temperature', fontsize=11)
        ax.set_ylabel('Moisture', fontsize=11)
        ax.set_title(f'Optimal Policy ({sun_names[s_idx]})', fontsize=11, fontweight='bold')
        for m in range(3):
            for t in range(3):
                ax.text(t, m, action_labels_short[matrix[m, t]],
                        ha='center', va='center', fontsize=7.5,
                        color='white' if matrix[m, t] in [1, 3] else 'black')

    patches = [mpatches.Patch(color=cmap(i), label=f'{i}: {action_labels_short[i]}')
               for i in range(7)]
    fig.legend(handles=patches, loc='lower center', ncol=4, fontsize=9,
               bbox_to_anchor=(0.5, -0.05))
    fig.suptitle('Q-Learning Learned Policy Heatmap', fontsize=14, fontweight='bold')
    plt.tight_layout()
    save_fig(fig, os.path.join(out_dir, 'hw1_policy_heatmap.png'))

    print("\n  All HW1 plots saved to:", out_dir)


#  Main
if __name__ == "__main__":
    EPISODES      = 8000
    ALPHA         = 0.1
    GAMMA         = 0.9
    EPSILON_START = 1.0
    EPSILON_DECAY = 0.9995
    EPSILON_MIN   = 0.01
    TEST_EPISODES = 200
    OUT_DIR       = "plots"

    q_table, ep_rewards, ep_epsilon = train_q_learning(
        episodes      = EPISODES,
        alpha         = ALPHA,
        gamma         = GAMMA,
        epsilon_start = EPSILON_START,
        epsilon_decay = EPSILON_DECAY,
        epsilon_min   = EPSILON_MIN,
    )

    print("\n  [Test Phase] Evaluating with Greedy Policy...")
    test_rewards = evaluate_policy(q_table, episodes=TEST_EPISODES)
    print(f"  Test Episodes : {TEST_EPISODES}")
    print(f"  Average Reward: {np.mean(test_rewards):.2f} ± {np.std(test_rewards):.2f}")
    print(f"  Max Reward    : {np.max(test_rewards):.0f}")
    print(f"  Min Reward    : {np.min(test_rewards):.0f}")

    moistures, temps, suns, trace_actions, trace_rewards = run_one_episode_trace(q_table)

    print_policy(q_table)

    generate_plots(ep_rewards, ep_epsilon, test_rewards,
                   moistures, temps, suns, trace_actions, trace_rewards,
                   q_table, out_dir=OUT_DIR)

    np.save(os.path.join(OUT_DIR, "q_table.npy"), q_table)
    np.save(os.path.join(OUT_DIR, "ql_ep_rewards.npy"), ep_rewards)
    np.save(os.path.join(OUT_DIR, "ql_ep_epsilon.npy"), ep_epsilon)
    np.save(os.path.join(OUT_DIR, "ql_test_rewards.npy"), test_rewards)