OVERVIEW
--------
Implement the MDP framework for an AI-Powered Smart Greenhouse and solve it
using the Q-Learning algorithm (tabular, model-free, off-policy TD method).

--------------------------------------------------------------------------------
REQUIREMENTS
--------------------------------------------------------------------------------
  Python     >= 3.10
  numpy      >= 1.24
  matplotlib >= 3.7

Install dependencies:
  pip install numpy matplotlib

--------------------------------------------------------------------------------
FILES
--------------------------------------------------------------------------------
  hw1_qlearning.py       — Main source code (environment + Q-Learning + plots)
  README_HW1.txt         — This file
  HW1_Report.docx        — Written report

--------------------------------------------------------------------------------
OUTPUT
--------------------------------------------------------------------------------
  • Trains Q-Learning agent for 8,000 episodes
  • Prints progress every 1,000 episodes (avg reward, epsilon)
  • Evaluates greedy policy for 200 test episodes
  • Prints the learned policy table (all 27 states → best action)
  • Saves 5 plots to plots/hw1_*.png
  • Saves Q-table and reward arrays to plots/*.npy

  Expected runtime: ~10 seconds (CPU)

--------------------------------------------------------------------------------
MDP DESIGN SUMMARY
--------------------------------------------------------------------------------

  State Space S : 3 sensor readings, each discretized to 3 bins → 27 states
    Moisture:     Dry (0–30%) | Optimal (30–70%) | Wet (70–100%)
    Temperature:  Low (<18°C) | Optimal (18–28°C) | High (>28°C)
    Sunlight:     Low (<300)  | Medium (300–700)  | High (>700 W/m²)

  Action Space A : 7 discrete actuator commands
    a0: Do nothing        a1: Turn ON pump      a2: Turn OFF pump
    a3: Turn ON heater    a4: Turn OFF heater
    a5: Open curtains     a6: Close curtains

  Reward Function R(s, a):
    +10 if moisture optimal,  -8 if dry (wilting risk),  -3 if wet
    +12 if temperature optimal, -10 if too cold, -6 if too hot
    + 6 if sunlight optimal,   -2 otherwise
    - 2 if pump ON  (water scarcity cost)
    - 5 if heater ON (peak electricity cost)
    - 1 if curtains moved (mechanical wear)
    + 3 bonus if both moisture AND temperature are optimal (synergy)
    - 4 extra penalty if moisture OR temperature at critical level

  Transition T : Stochastic — 75% success probability per actuator action
                 Natural drift (drying, weather noise) without action

  Discount Factor: γ = 0.9     Horizon H: 24 steps (one greenhouse day)

--------------------------------------------------------------------------------
ALGORITHM
--------------------------------------------------------------------------------

  Q-Learning update rule:
    Q(s, a) ← Q(s, a) + α · [ r + γ · max_{a'} Q(s', a') − Q(s, a) ]

  Hyperparameters:
    Learning rate α      : 0.1
    Discount factor γ    : 0.9
    Epsilon start        : 1.0  (full exploration)
    Epsilon decay        : 0.9995 per episode
    Epsilon min          : 0.01
    Training episodes    : 8,000
    Max steps / episode  : 24

  Q-table size: 3 × 3 × 3 × 7 = 189 entries

--------------------------------------------------------------------------------
KEY RESULTS
--------------------------------------------------------------------------------

  Training final avg reward (last 500 episodes) : 196.3
  Test avg reward (200 greedy episodes)         : 206.1 ± 107.4
  Best test episode reward                      : 486
  Training time                                 : ~10 seconds

  Learned policy highlights:
    Moisture = Dry  (any)              → pump_on
    Moisture = Opt, Temperature = Low  → heater_on
    Moisture = Opt, Temperature = High → heater_off
    All parameters Optimal             → do_nothing  (conserve resources)

================================================================================
