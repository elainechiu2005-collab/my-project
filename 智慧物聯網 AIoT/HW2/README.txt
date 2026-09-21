OVERVIEW
--------
Implement Deep Q-Network (DQN) for the same Smart Greenhouse MDP from HW1,
then compare training trend and performance against the Q-Learning solution.

--------------------------------------------------------------------------------
REQUIREMENTS
--------------------------------------------------------------------------------
  Python     >= 3.10
  numpy      >= 1.24
  matplotlib >= 3.7
  torch      >= 2.0   (PyTorch — MPS / CUDA / CPU auto-selected)

--------------------------------------------------------------------------------
Output
--------------------------------------------------------------------------------
  • Loads Q-Learning results (plots/q_table.npy, ql_ep_rewards.npy, etc.)
  • Trains DQN agent for 8,000 episodes (same environment as HW1)
  • Prints progress every 1,000 episodes (avg reward, loss, epsilon)
  • Evaluates DQN greedy policy for 200 test episodes
  • Prints DQN policy table and final comparison summary table
  • Saves 6 comparison plots to plots/hw2_*.png
  • Saves DQN results to plots/dqn_*.npy

--------------------------------------------------------------------------------
DQN ARCHITECTURE
--------------------------------------------------------------------------------

  State encoding  : one-hot (9-dim) for (moisture, temperature, sunlight)
                    e.g. (Dry, Optimal, Low) → [1,0,0, 0,1,0, 1,0,0]

  Network         : 9 → FC(64) → ReLU → FC(64) → ReLU → FC(7)
  Optimizer       : Adam (lr = 0.001)
  Loss            : MSE  (Bellman error)

  Key enhancements over Q-Learning:
    1. Experience Replay  — buffer size 10,000; batch size 64
                            breaks temporal correlations between samples
    2. Target Network     — frozen copy synced every 200 gradient steps
                            provides stable Bellman regression targets
    3. Gradient Clipping  — max norm = 10.0
                            prevents exploding gradients from outlier transitions

  Bellman update:
    y = r + γ · max_{a'} Q(s', a'; θ⁻)     ← uses FROZEN target net θ⁻
    L = E[ (Q(s, a; θ) − y)² ]             ← MSE loss on policy net θ

--------------------------------------------------------------------------------
HYPERPARAMETERS (same epsilon schedule as HW1 for fair comparison)
--------------------------------------------------------------------------------

  Learning rate        : 0.001 (Adam)
  Discount factor γ    : 0.9
  Epsilon start        : 1.0
  Epsilon decay        : 0.9995 per episode
  Epsilon min          : 0.01
  Batch size           : 64
  Replay buffer        : 10,000 transitions
  Target update freq   : every 200 gradient steps
  Training episodes    : 8,000
  Max steps / episode  : 24
  Device               : MPS (Apple Silicon) / CUDA / CPU (auto-detected)

--------------------------------------------------------------------------------
COMPARISON RESULTS
--------------------------------------------------------------------------------

  Metric                            Q-Learning      DQN
  ──────────────────────────────────────────────────────
  Train avg reward (last 500 ep)       196.3        236.2   ← DQN +20%
  Train best episode reward              557          571
  Test avg reward (200 ep)             206.1        220.0   ← DQN +7%
  Test std deviation                   107.4        108.7
  Test median reward                   204.0        214.5
  Convergence speed                   ~2,000 ep   ~3,000 ep ← Q-Learning faster
  Training time                        ~10 sec     ~729 sec  ← Q-Learning faster
  Memory footprint                    189 floats   ~37K params

  Key observations:
  → DQN achieves higher final reward via function generalisation & replay
  → Q-Learning converges faster: no warm-up, simpler 189-value optimisation
  → Both learn correct policy: pump when dry, heat when cold, do_nothing at optimum
  → DQN preferred for real IoT deployment (continuous states, many sensors)
  → Q-Learning preferred for resource-constrained devices, small state spaces
