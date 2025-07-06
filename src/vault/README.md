# Delta Neutral Vault

A simple ERC-4626 vault implementation for delta-neutral strategies on top of EulerSwap.

## Overview

This vault provides a simple interface for users to deposit USDC and participate in a delta-neutral strategy. The strategy logic is handled off-chain through rebalancing operations.

## Key Features

- **Simple deposits**: Users deposit USDC only
- **Proportional withdrawals**: Users receive proportional shares of USDC collateral, WETH holdings, and WETH debt
- **Off-chain rebalancing**: Strategy logic handled externally through owner functions
- **Slippage protection**: Withdrawals include deadline and minimum output protection
- **Uninstall/Reinstall**: Pool parameters can be updated through curve reinstallation

## Architecture

```
User USDC → Vault → Euler Vaults → EulerSwap Curve
                ↓
            Proportional Assets (USDC collateral, WETH, WETH debt)
```

## Usage

### For Users

1. **Deposit USDC**:
   ```solidity
   vault.deposit(100_000e6, user);
   ```

2. **Withdraw proportionally**:
   ```solidity
   uint256[] memory minOut = new uint256[](3);
   minOut[0] = 90_000e6;  // min USDC
   minOut[1] = 45e18;     // min WETH
   minOut[2] = 50e18;     // max WETH debt
   
   vault.withdraw(assets, receiver, owner, minOut, deadline);
   ```

### For Vault Owner (Rebalancer)

1. **Deploy USDC to Euler**:
   ```solidity
   vault.deployToEuler();
   ```

2. **Borrow WETH**:
   ```solidity
   vault.borrowWeth(1000e18);
   ```

3. **Install EulerSwap curve**:
   ```solidity
   vault.installPool(params, initialState, salt);
   ```

4. **Uninstall curve**:
   ```solidity
   vault.uninstallPool();
   ```

## Contract Functions

### Public Functions

- `deposit(uint256 assets, address receiver) → uint256 shares`
- `withdraw(uint256 assets, address receiver, address owner, uint256[] minOut, uint256 deadline) → uint256 shares`
- `getPositions() → (uint256 usdcCollateral, uint256 wethBalance, uint256 wethDebt, address activePool)`
- `previewProportionalWithdraw(address user) → (uint256 usdcAmount, uint256 wethAmount, uint256 wethDebt)`

### Owner Functions

- `installPool(params, initialState, salt)` - Deploy new EulerSwap curve
- `uninstallPool()` - Remove current curve
- `deployToEuler()` - Send USDC to Euler vault as collateral
- `withdrawFromEuler(uint256 amount)` - Withdraw USDC from Euler vault
- `borrowWeth(uint256 amount)` - Borrow WETH from Euler vault  
- `repayWeth(uint256 amount)` - Repay WETH debt

## Deployment

1. **Update addresses** in `script/DeployDeltaNeutralVault.s.sol`
2. **Deploy**:
   ```bash
   forge script script/DeployDeltaNeutralVault.s.sol --broadcast --rpc-url $RPC_URL
   ```

## Testing

Run tests:
```bash
forge test -vv
```

## Security Considerations

- **Debt Transfer**: Current implementation simplifies debt transfer - in production, proper EVC debt transfer mechanics should be implemented
- **Slippage Protection**: Users should always specify appropriate `minOut` values
- **Owner Trust**: Vault owner has significant control over rebalancing operations
- **Emergency Functions**: Consider adding emergency withdrawal mechanisms

## Future Enhancements

- Implement proper EVC debt transfer for withdrawals
- Add automated slippage calculation
- Implement time-weighted average pricing for curve installations
- Add emergency pause functionality
- Implement fee collection mechanisms 