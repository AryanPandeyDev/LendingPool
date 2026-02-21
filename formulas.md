1. Utilization (How “used” the pool is)
utilization = totalBorrowed / totalLiquidity


Scaled in Solidity with 1e18.

Meaning:
What fraction of deposited funds is currently lent out.

2. Borrow Interest Rate (What borrowers pay)
Simple MVP version (one slope)
borrowRate = baseRate + utilization × slope


Example:
base = 2%
slope = 8%

At 50% util → 6%

Optional (later): Two-slope version
if util ≤ kink:
  rate = base + util × slope1
else:
  rate = rateAtKink + (util - kink) × slope2


Not for v1.

3. Lender Interest Rate (What depositors earn)
lenderRate = borrowRate × utilization × (1 - reserveFactor)


ReserveFactor = protocol cut (5% etc).

4. Interest Accrual Factor (Convert APR to Time)
interestFactor = rate × timeElapsed / YEAR


Where:

YEAR = 365 days in seconds

5. Borrow Index Update
borrowIndex = borrowIndex × (1 + borrowRate × dt / YEAR)


Tracks debt growth.

6. Liquidity Index Update
liquidityIndex = liquidityIndex × (1 + lenderRate × dt / YEAR)


Tracks deposit growth.

7. User Debt (How much borrower owes)
debt = principal × (currentBorrowIndex / userBorrowIndex)


No per-user updates.

Uses snapshots.

8. User Deposit Balance (How much lender owns)
balance = deposit × currentLiquidityIndex / userLiquidityIndex


Same idea.

9. Collateral Value (In USD or asset units)
collateralValue = collateralAmount × oraclePrice

10. Borrow Limit (LTV rule)
maxBorrow = collateralValue × LTV


Example: LTV = 50%

11. Health Factor (Liquidation metric)
healthFactor = (collateralValue × liquidationThreshold) / debt


If < 1 → liquidatable.

12. Liquidation Bonus
collateralToSeize = repaidDebt × (1 + liquidationBonus)


Example: bonus = 5%

13. Total Lender Yield (Accounting Check)
totalInterest = totalBorrowed × borrowRate
lenderShare = totalInterest × (1 - reserveFactor)


Matches index math.

14. Solidity Scaling Rule (Very Important)

All decimals are scaled:

1.0 = 1e18


So:

50% = 0.5e18
2%  = 0.02e18


Every multiply → divide by 1e18.

Mental Map (How Everything Connects)
Deposits → totalLiquidity
Borrows  → totalBorrowed
      ↓
 utilization
      ↓
 borrowRate
      ↓
 lenderRate
      ↓
 indexes
      ↓
 user balances


One pipeline.

MVP Parameter Set (Recommended)

You can start with:

baseRate = 2%
slope = 8%
reserve = 5%
LTV = 50%
liqThreshold = 80%
liqBonus = 5%


Solid defaults.