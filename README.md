# LendingPool Protocol

A single-asset, overcollateralised lending pool built in Solidity. Lenders deposit USDC to earn interest; borrowers pledge WETH as collateral to borrow USDC. Interest accrues continuously via a ray-indexed model inspired by **Aave V2**, and a kinked interest-rate curve ensures capital-efficient pricing.

> Built with **Foundry** · Solidity `^0.8.24` · Chainlink Price Feeds · OpenZeppelin

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Interest Rate Model](#interest-rate-model)
- [Index-Based Interest Accrual](#index-based-interest-accrual)
- [Liquidation Mechanism](#liquidation-mechanism)
- [Protocol Revenue](#protocol-revenue)
- [Security Assumptions](#security-assumptions)
- [Project Structure](#project-structure)
- [Getting Started](#getting-started)
- [Testing](#testing)
- [Deployment](#deployment)

---

## Overview

| Feature | Detail |
|---|---|
| **Underlying Asset** | USDC (ERC-20) |
| **Collateral Asset** | WETH (ERC-20) |
| **Price Oracle** | Chainlink ETH/USD |
| **Liquidation Threshold** | 75 % |
| **Liquidation Bonus** | 5 % |
| **Reserve Factor** | 5 % |
| **Interest Model** | Kinked (two-slope) |
| **Kink Utilisation** | 80 % |

### Core User Flows

```
Lender                                Borrower
  │                                      │
  ├─ depositToken(amount)                ├─ depositCollateral(amount)
  │   → earns interest over time         │
  │                                      ├─ borrowToken(amount)
  ├─ withdrawToken(amount)               │   → must maintain HF ≥ 1
  │   → receives principal + interest    │
  │                                      ├─ repayDebt(amount)
  │                                      │
  │                                      ├─ redeemCollateral(amount)
  │                                      │   → must maintain HF ≥ 1
  │                                      │
  Liquidator ─── liquidate(user, debt) ──┘
                  → repays debt, seizes collateral + 5% bonus
```

---

## Architecture

The protocol consists of one core contract and two helper libraries:

```
src/
├── LendingPool.sol              # Core protocol logic
├── interface/
│   └── ILendingPool.sol         # External interface
└── libraries/
    ├── InterestLib.sol           # Interest rate math (pure)
    └── OracleLib.sol             # Chainlink staleness check
```

### LendingPool.sol

The single entry point for all protocol interactions. It manages:

- **Lender deposits & withdrawals** — tracked via normalised balances against a cumulative liquidity index.
- **Borrower collateral, borrows & repayments** — tracked via normalised debt against a cumulative borrow index.
- **Liquidations** — any third party can repay an underwater borrower's debt in exchange for their collateral plus a bonus.
- **Protocol reserves** — a fraction of borrower interest is retained by the protocol and withdrawable by the operator.

### InterestLib.sol

A stateless, pure math library containing:

| Function | Purpose |
|---|---|
| `calculateUtilization` | `totalBorrowed / totalLiquidity` |
| `calculateBorrowRate` | Kinked interest-rate curve |
| `calculateLenderInterest` | Lender rate after reserve factor |
| `calculateIndexUpdate` | Multiplicative growth factor for indexes |
| `calculateInterestAccrued` | Absolute interest over a time period |

### OracleLib.sol

A thin wrapper around Chainlink's `AggregatorV3Interface` that reverts with `OracleLib__StalePrice` if the feed hasn't been updated in **3 hours**.

---

## Interest Rate Model

The protocol uses a **kinked (two-slope) interest rate model**, identical in spirit to Aave and Compound:

```
Borrow Rate
    │
    │                          ╱  slope = slopeAtKink (100%)
    │                        ╱
    │                      ╱
    │         ╱───────────╱  ← kink at 80% utilisation
    │       ╱  slope (8%)
    │     ╱
    │   ╱
    │ ╱  baseRate (2%)
    └──────────────────────────── Utilisation
    0%                  80%  100%
```

### Formulas

**Utilisation:**

```
U = totalBorrowed / totalLiquidity
```

**Borrow Rate (annualised):**

```
if U < KINK (80%):
    borrowRate = baseRate + (U × slope)
                = 0.02   + (U × 0.08)

if U ≥ KINK:
    borrowRate = baseRateAtKink + ((U − KINK) × slopeAtKink)
                = 0.10          + ((U − 0.80) × 1.00)
```

**Lender Rate (annualised):**

```
lenderRate = borrowRate × U × (1 − reserveFactor)
           = borrowRate × U × 0.95
```

### Default Parameters

| Parameter | Value | Meaning |
|---|---|---|
| `baseRate` | 2 % (`2e16`) | Minimum borrow APR |
| `slope` | 8 % (`8e16`) | Rate growth per unit utilisation below kink |
| `baseRateAtKink` | 10 % (`10e16`) | Borrow APR at exactly 80 % utilisation |
| `slopeAtKink` | 100 % (`100e16`) | Steep slope above kink to discourage over-utilisation |
| `reserveFactor` | 5 % (`5e16`) | Protocol's cut of borrower interest |
| `KINK` | 80 % (`80e16`) | Utilisation threshold for curve steepening |

### Example

At 50 % utilisation:
- Borrow rate = `0.02 + (0.50 × 0.08)` = **6 % APR**
- Lender rate = `0.06 × 0.50 × 0.95` = **2.85 % APR**

At 90 % utilisation:
- Borrow rate = `0.10 + ((0.90 − 0.80) × 1.00)` = **20 % APR**
- Lender rate = `0.20 × 0.90 × 0.95` = **17.1 % APR**

---

## Index-Based Interest Accrual

Interest does NOT compound per-user on every block. Instead, the protocol maintains two **cumulative indexes** that grow over time:

| Index | Tracks | Updated By |
|---|---|---|
| `s_liquidityIndex` | Lender interest accrual | `_updateLiquidityIndex()` |
| `s_borrowerIndex` | Borrower interest accrual | `_updateBorrowerIndex()` |

### How It Works

1. **On every state-changing call**, the relevant index is updated:

```
dt = block.timestamp − lastUpdate
factor = 1 + (rate × dt / SECONDS_PER_YEAR)
index = index × factor / 1e18
```

2. **Per-user balances are "rebased"** against the index:

```
updatedBalance = storedBalance × currentIndex / userSnapshotIndex
```

3. The user's snapshot index is set to the current global index.

This means a user who deposited 1000 USDC when `liquidityIndex = 1.0e18` and checks their balance when `liquidityIndex = 1.05e18` will see:

```
balance = 1000 × 1.05e18 / 1.0e18 = 1050 USDC
```

> **Note:** The protocol uses **simple (linear) interest** per accrual period, not continuous compounding. Compounding occurs implicitly because the index is multiplied on each update.

---

## Liquidation Mechanism

When a borrower's **health factor** drops below 1.0, anyone can liquidate them:

### Health Factor

```
                 collateralUSD × LIQUIDATION_THRESHOLD / 100
healthFactor = ───────────────────────────────────────────────
                              debt
```

Where `collateralUSD = collateralAmount × ethPrice`.

- **Health Factor ≥ 1.0** → Safe, cannot be liquidated
- **Health Factor < 1.0** → Underwater, open for liquidation

### Liquidation Flow

1. Liquidator calls `liquidate(borrower, debtToCover)`
2. Protocol verifies `healthFactor < 1.0`
3. Collateral to seize = `debtToCover` converted to collateral tokens **+ 5 % bonus**
4. Collateral transferred: borrower → liquidator
5. Debt tokens transferred: liquidator → pool
6. Protocol verifies health factor has improved

### Example

- Borrower has 1 WETH ($2000) collateral and $1600 debt
- Health factor = `(2000 × 0.75) / 1600 = 0.9375` → **underwater**
- Liquidator covers $800 of debt
- Liquidator receives `$800 + 5% = $840` worth of WETH = **0.42 WETH**
- Borrower's remaining: 0.58 WETH ($1160) collateral, $800 debt
- New health factor = `(1160 × 0.75) / 800 = 1.0875` → **safe**

---

## Protocol Revenue

The protocol earns revenue through the **reserve factor** — a percentage of all borrower interest that is retained instead of being distributed to lenders.

```
protocolRevenue = interestAccrued × reserveFactor
                = interestAccrued × 0.05
```

Protocol reserves accumulate in `s_protocolReserve` and can only be withdrawn by the **protocol operator** (deployer) via `withdrawProtocolReserves()`.

---

## Security Assumptions

### Trust Model

| Actor | Trust Level | Notes |
|---|---|---|
| **Protocol Operator** | Trusted | Can withdraw reserves; set at deploy time; immutable |
| **Lenders** | Untrusted | Interact via public functions; protected by reentrancy guards |
| **Borrowers** | Untrusted | Health factor enforced on every borrow / redeem |
| **Liquidators** | Untrusted | Can only liquidate underwater positions; bounded by collateral |
| **Chainlink Oracle** | Trusted | Single point of failure — if the feed is wrong, so are liquidations |

### Key Assumptions

1. **Oracle Correctness** — The protocol trusts the Chainlink ETH/USD feed to return accurate prices. A stale or manipulated feed can cause incorrect liquidations or allow under-collateralised positions. The `OracleLib` staleness check (3-hour timeout) mitigates feed outages but cannot prevent oracle manipulation.

2. **ERC-20 Compliance** — Both USDC and WETH must be standard ERC-20 tokens that return `true` on success. Fee-on-transfer or rebasing tokens are **not supported** and will break accounting.

3. **Single Collateral Type** — The pool only supports one collateral asset (WETH). There is no cross-collateralisation or multi-asset support.

4. **No Flash Loan Protection** — The protocol does not have explicit flash loan guards beyond reentrancy protection. An attacker could theoretically flash-borrow to manipulate pool state within a single transaction, though the health factor check and `ReentrancyGuard` limit the attack surface.

5. **Linear Interest Approximation** — Interest is calculated using simple (linear) rates per time period. Over very long periods without any interaction, the accrued interest may slightly differ from a continuously-compounded model.

6. **Immutable Parameters** — All interest rate parameters (`baseRate`, `slope`, `slopeAtKink`, `reserveFactor`), the protocol operator, and asset addresses are set at deploy time and **cannot be changed**. Governance or upgradeability must be added via a proxy pattern if needed.

7. **No Bad Debt Socialisation** — If a borrower's collateral drops so fast that liquidation cannot cover their debt, the resulting bad debt is not socialised across lenders. The pool will be insolvent by the shortfall amount.

### Protections in Place

- **ReentrancyGuard** on all state-changing external/public functions
- **Health factor checks** on borrow, redeem, and post-liquidation
- **Chainlink staleness check** with 3-hour timeout
- **ETH rejection** via `receive() { revert(); }`
- **moreThanZero modifier** preventing zero-amount operations

---

## Project Structure

```
lending-protocol/
├── src/
│   ├── LendingPool.sol                        # Core contract
│   ├── interface/
│   │   └── ILendingPool.sol                   # External interface
│   └── libraries/
│       ├── InterestLib.sol                    # Interest math
│       └── OracleLib.sol                      # Oracle wrapper
├── script/
│   ├── DeployLendingPool.s.sol                # Forge deployment script
│   └── HelperConfig.s.sol                     # Network config & mocks
├── test/
│   ├── Invariant/
│   │   ├── failOnRevert/                      # Strict invariant suite (9 invariants)
│   │   │   ├── FailOnRevertHandler.t.sol
│   │   │   └── FailOnRevertInvariants.t.sol
│   │   └── continueOnRevert/                  # Loose invariant suite (9 invariants)
│   │       ├── ContinueOnRevertHandler.t.sol
│   │       └── ContinueOnRevertInvariants.t.sol
│   ├── fuzz/                                  # Fuzz tests
│   ├── unit/                                  # Unit tests
│   └── mocks/
│       └── FakeERC20.sol                      # Mintable mock token
├── foundry.toml                               # Foundry config
└── README.md
```

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)

### Install Dependencies

```bash
forge install
```

### Build

```bash
forge build
```

---

## Testing

The test suite includes **110 tests** across unit, fuzz, and invariant categories.

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run only invariant tests
forge test --match-path "test/Invariant/**"
```

### Invariant Test Suites

The protocol has **two** invariant test suites, each testing **9 properties**:

| # | Invariant | Description |
|---|---|---|
| 1 | Balance ≥ Reserve | Contract USDC balance covers protocol reserves |
| 2 | Liquidity ≥ Borrowed | Total deposits always ≥ total borrows |
| 3 | Indexes Initialised | Both indexes ≥ 1e18, lastUpdate ≤ now |
| 4 | Getters Never Revert | All view functions are safe to call |
| 5 | Solvency | Contract balance covers lender + reserve obligations |
| 6 | Borrow Index ≥ Liquidity Index | Reserve factor guarantee |
| 7 | All Borrowers Healthy | Every borrower has health factor ≥ 1 |
| 8 | Utilisation ≤ 100 % | Cannot borrow more than deposited |
| 9 | Index Monotonicity | Indexes never decrease |

**Fail-on-revert suite** — Handler carefully bounds all inputs so LendingPool never reverts. Every call is a valid state transition, giving maximum confidence.

**Continue-on-revert suite** — Handler uses loose bounds; invalid calls revert inside LendingPool and are swallowed. This catches edge cases the strict handler's bounding might mask.

---

## Deployment

### Local (Anvil)

```bash
# Start local chain
anvil

# Deploy
forge script script/DeployLendingPool.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

### Sepolia Testnet

```bash
forge script script/DeployLendingPool.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### Mainnet

```bash
forge script script/DeployLendingPool.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

> **⚠️ Warning:** The protocol has not been formally audited. Deploy to mainnet at your own risk.

---

## License

MIT
