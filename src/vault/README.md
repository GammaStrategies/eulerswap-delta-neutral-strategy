# Delta Neutral Vault

An advanced ERC-4626 vault implementation for delta-neutral strategies on top of EulerSwap with sophisticated position management and user isolation features.

## Overview

This vault provides a comprehensive interface for users to deposit USDC and participate in a delta-neutral strategy. The vault features automatic sub-account creation for user isolation, comprehensive rebalancing capabilities, and flexible lending/borrowing strategies.

## Key Features

- **Delta-neutral strategy**: Combines USDC collateral and WETH borrowing to maintain stable value exposure
- **EulerSwap integration**: Uses concentrated liquidity pools for efficient capital utilization  
- **Sub-account withdrawals**: Automatic creation of isolated EVC sub-accounts for user withdrawal safety
- **Enhanced safety protections**: Prevents fund lockup with deposit limits and forced final withdrawals
- **Flexible rebalancing**: Owner can adjust position parameters while users retain full control of their funds
- **ERC4626 compliance**: Standard vault interface for deposits, withdrawals, and share accounting
- **Flexible strategies**: Support for both USDC→WETH and WETH→USDC borrowing strategies
- **Position isolation**: Each withdrawal creates a separate sub-account preventing cross-user risk
- **Slippage protection**: Withdrawals include deadline and minimum/maximum output protection
- **Dynamic pool management**: Pool parameters can be updated through comprehensive rebalancing

## Architecture

```
User USDC → Vault → Euler Vaults → EulerSwap Curve
                ↓
            Sub-Account Creation
                ↓
            Isolated User Positions (USDC collateral, WETH, WETH debt)
```

## Usage

### Deposits

```solidity
vault.deposit(1000e6, userAddress); // Deposit 1,000 USDC
```


### Withdrawals

The vault provides **only sub-account withdrawals** for maximum user safety:

```solidity
// Withdraw to automatically-created sub-account
vault.withdrawToSubAccount(
    500e6,                    // Amount of assets to withdraw
    userAddress,              // Receiver of the sub-account
    userAddress,              // Owner of the shares
    [900e6, 0.4e18, 0.5e18], // [minUSDC, minWETH, maxWETHDebt]
    block.timestamp + 300     // 5-minute deadline
);
```


### Utility Functions

```solidity
// Preview next sub-account address
address futureSubAccount = vault.previewWithdrawalSubAccount(user);

// Check nonce usage
(uint256 used, uint256 remaining) = vault.getUserNonceInfo(user);
```

### For Vault Owner (Strategy Management)

1. **Comprehensive Rebalance** (Recommended):
   ```solidity
   vault.rebalance(
       50_000e6,    // USDC to lend
       20e18,       // WETH to borrow
       10e18,       // WETH to lend
       5_000e6,     // USDC to borrow
       newParams,   // New pool parameters
       newInitialState,
       newSalt
   );
   ```

2. **Individual Operations**:
   ```solidity
   // Lending operations
   vault.lendUsdc();           // Lend all available USDC
   vault.lendWeth();           // Lend all available WETH
   
   // Borrowing operations
   vault.borrowWeth(1000e18);  // Borrow WETH against collateral
   vault.borrowUsdc(5000e6);   // Borrow USDC against collateral
   
   // Repayment operations
   vault.repayWeth(500e18);    // Repay WETH debt (0 = repay all)
   vault.repayUsdc(2500e6);    // Repay USDC debt (0 = repay all)
   ```

3. **Pool Management**:
   ```solidity
   // Install new pool
   vault.installPool(params, initialState, salt);
   
   // Remove current pool
   vault.uninstallPool();
   ```

## Contract Functions

### Public Functions

- `deposit(uint256 assets, address receiver) → uint256 shares` - Standard ERC-4626 deposit
- `withdrawToSubAccount(uint256 assets, address receiver, address owner, uint256[] minOut, uint256 deadline) → (uint256 shares, address subAccount)` - Withdraw to isolated sub-account with safety protections
- `getPositions() → (uint256 usdcCollateral, uint256 wethBalance, uint256 wethDebt, address activePool)` - Get current vault positions
- `previewProportionalWithdraw(address user) → (uint256 usdcAmount, uint256 wethAmount, uint256 wethDebt)` - Preview withdrawal amounts
- `previewWithdrawalSubAccount(address user) → address` - Preview next sub-account address
- `getUserNonceInfo(address user) → (uint256 used, uint256 remaining)` - Get user's sub-account nonce info (max 255 usable)

### Owner Functions

#### Comprehensive Management
- `rebalance(usdcToLend, targetWethBorrow, wethToLend, targetUsdcBorrow, newParams, newInitialState, newSalt)` - Complete strategy rebalancing

#### Individual Operations
- `lendUsdc()` - Lend all available USDC as collateral
- `lendWeth()` - Lend all available WETH as collateral
- `borrowWeth(uint256 amount)` - Borrow WETH against collateral
- `borrowUsdc(uint256 amount)` - Borrow USDC against collateral
- `repayWeth(uint256 amount)` - Repay WETH debt (0 = repay all)
- `repayUsdc(uint256 amount)` - Repay USDC debt (0 = repay all)

#### Pool Management
- `installPool(params, initialState, salt)` - Deploy new EulerSwap pool
- `uninstallPool()` - Remove current pool

## Deployment

1. **Set environment variables**:
   ```bash
   export PRIVATE_KEY=0x...
   export RPC_URL=https://...
   ```

2. **Deploy with contract addresses** (example for Unichain):
   ```bash
   forge script script/DeployDeltaNeutralVault.s.sol:DeployDeltaNeutralVault \
     --sig "run(address,address,address,address,address,address)" \
     0x078D782b760474a361dDA0AF3839290b0EF57AD6 \
     0x4200000000000000000000000000000000000006 \
     0x45b146BC07c9985589B52df651310e75C6BE066A \
     0x2A1176964F5D7caE5406B627Bf6166664FE83c60 \
     0x6eAe95ee783e4D862867C4e0E4c3f4B95AA682Ba \
     0xD49181c522eCDB265f0D9C175Cf26FFACE64eAD3 \
     --broadcast --rpc-url $RPC_URL
   ```

   **Parameters (in order):**
   - `usdc`: USDC token address
   - `weth`: WETH token address  
   - `eulerSwapFactory`: EulerSwap Factory address
   - `evc`: Ethereum Vault Connector address
   - `usdcVault`: Euler USDC Vault address  
   - `wethVault`: Euler WETH Vault address

## Testing

Run tests:
```bash
forge test -vv
```

## Security Considerations

- **Sub-Account Isolation**: Each withdrawal creates an isolated EVC sub-account, preventing cross-user contamination and providing individual position control
- **Enhanced Fund Protection**: Multiple safety mechanisms prevent user fund lockup:
  - Deposit blocking when approaching nonce limit (255)
  - Forced full withdrawal on final nonce to ensure complete exit
  - No legacy withdrawal paths that could complicate fund recovery
- **Position Transfer Mechanics**: The vault implements proper EVC position transfer mechanics using sub-account borrowing and collateral enabling
- **Slippage Protection**: Users must specify appropriate `minOut` values for USDC/WETH minimums and maximum debt tolerance
- **Owner Trust**: Vault owner has significant control over rebalancing operations but cannot access user funds directly
- **Nonce Management**: Each user has up to 255 usable sub-accounts (nonce 0-255) with automatic safety enforcement
- **Deadline Protection**: All withdrawals include deadline checks to prevent transaction replay attacks
- **Rebalance Atomicity**: The comprehensive rebalance function ensures atomic position changes and pool reinstallation

## Known Limitations

- **Sub-Account Limit**: Each user limited to 255 withdrawals total (clean exit design)
- **Pool Dependency**: Strategy effectiveness depends on EulerSwap pool liquidity and parameters

## Future Enhancements

- Implement fee collection mechanisms for vault operation costs
- Implement automated rebalancing triggers based on market conditions