# Backtest of a delta-neutral market-making strategy executable on EulerSwap

## 1. Target strategy on EulerSwap

This strategy is designed for **EulerSwap**, a novel AMM protocol that integrates lending and swapping into a unified architecture. The core goal is to remain **delta-neutral** while capturing fees from market-making activity, by dynamically adjusting the liquidity curve.

### 🧩 Core mechanism

- The market-maker **wants exposure to token Y only** (typically a stablecoin like USDC, USDT, DAI, etc.).
- They **lend token Y** on Euler (earning interest) and **borrow token X** (a volatile asset like ETH, BTC, UNI, etc.).
- Both tokens are used to deploy a **custom individual liquidity curve** on EulerSwap.

At initialization, the delta in token X is neutral:

- **Long X** via the tokens X in the curve (assets) 
- **Short X** via the tokens X borrowed (liabilities)

### 🛡️ Modes

As swaps are routed to the curve, the delta (normalized by liabilities) can get away from 0. When this distance exceeds a threshold, the **neutralization mode** is activated:

- The current curve is **uninstalled**.
- A new curve is installed with:
  - Equilibrium price reset to current market price
  - **Asymmetric extreme concentrations**:
    - One side with very **high** concentration (flat, low slippage)
    - One side with very **low** concentration (steep, high slippage)
- This acts as a **liquidity filter**: only swaps that neutralize the delta are routed through this curve

When the normalized delta gets back within the threshold, the **cruise mode** is reactivated and the curve is reinstalled, with an equilibrium price reset to current market price and symmetric moderate concentrations.

### 📉 Price-driven rebalance

When the price gets too far away from the equilibrium price, a rebalance is triggered and the curve is reinstalled, with an equilibrium price reset to current market price and concentrations based on the current mode (neutralization or cruise).

## 2. Proxy strategy on Uniswap v3

Despite the relative simplicity of the strategy presented above, it is currently **impossible to empirically backtest it on EulerSwap** due to:

- 📉 **Lack of historical data**  
EulerSwap is still in its early stages, so historical data on volume and liquidity is too limited if not unavailable.

- 🧠 **Proprietary routing logic**  
Every market maker sets its own curve. The router decides which curve to swap against based on slippage, which is quite hard to simulate even with access to the router’s internal logic.

### 🛠️ Solution: equivalent strategy on Uniswap v3

To validate the strategy, we built a **proxy version on Uniswap v3** that mimics the logic of the target strategy:

- Liquidity is split into:
  - A **base position**, range-bound around the market
  - A **limit position**, created with leftover tokens after minting the base

- The strategy rebalances when:
  - The market price exits a defined range  
  - The normalized delta exceeds a threshold

- Lending and borrowing are simulated off-chain with compounding APYs.

#### 🧪 Dataset

The backtesting script (backtest.py) uses a tailored dataset (swaps.csv) containing the historical swap data of a given pool, including the liquidity in the current range at each swap.  
> ⚠️ These datasets are generated using proprietary data and script not disclosed in this repository.

## 3. Results

### 💧 Pool details

- **Network**: Polygon  
- **Address**: 0x4ccd010148379ea531d6c587cfdd60180196f9b1
- **Token X**: WETH
- **Token Y**: USDT
- **Fee**: 0.3%
- **Spacing**: 60

### ⚙️ Strategy parameters

- Bounds and thresholds were selected using a proprietary optimizer.
- Parameters were fixed over the entire backtest window.

### 📊 Performance summary

| Metric           | Value        |
|------------------|--------------|
| Rebalances       | 6667         |
| APY              | 25.55%       |
| Maximum drawdown | -5.26%       |
| Calmar ratio     | 4.86         |
| Sharpe ratio     | 3.91         |

These results demonstrate strong and stable fee capture, with robust risk-adjusted performance under volatile market conditions.

## 4. Why EulerSwap Would Perform Even Better

We believe the strategy would **outperform on EulerSwap** for the following reasons:

### ✅ Better Auto-Hedging

- Because each LP defines their own liquidity curve, one can **intentionally favor delta-neutralizing trades** by tuning slippage asymmetry.
- Unfavorable flow can be passively filtered via steep slippage.

### ✅ Superior Capital Efficiency

- No idle assets: funds are either earning interest (lent) or deployed (LP'd).
- Native leverage is possible via Euler's lending market.

### ✅ Continuous Liquidity

- Unlike Uniswap v3, EulerSwap does not use discrete ticks.
- This allows **finer control over concentration** and **more capital-efficient positioning**.

---

We conclude that while the proxy strategy on Uniswap v3 offers robust empirical validation, its theoretical performance would be **even stronger when executed natively on EulerSwap**.
