// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

import {IEulerSwapFactory} from "../interfaces/IEulerSwapFactory.sol";
import {IEulerSwap} from "../interfaces/IEulerSwap.sol";
import {IEVault, IBorrowing, IRiskManager} from "evk/EVault/IEVault.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

/**
 * @title DeltaNeutralVault
 * @notice Simple ERC-4626 vault for delta-neutral strategy on EulerSwap
 * @dev Deposits take USDC only, withdrawals distribute proportional assets
 */
contract DeltaNeutralVault is ERC4626, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    /// @notice EulerSwap factory contract
    IEulerSwapFactory public immutable factory;
    
    /// @notice Ethereum Vault Connector
    IEVC public immutable evc;
    
    /// @notice USDC vault (collateral)
    IEVault public immutable usdcVault;
    
    /// @notice WETH vault (borrowing)
    IEVault public immutable wethVault;
    
    /// @notice WETH token
    IERC20 public immutable weth;
    
    /// @notice Current active pool address
    address public currentPool;
    
    /// @notice Last used curve parameters (for reinstalling)
    IEulerSwap.Params public lastParams;
    IEulerSwap.InitialState public lastInitialState;
    bytes32 public lastSalt;

    // Track sub-account nonces for each user
    mapping(address => uint256) public userNonces;

    // ============ Events ============

    event PoolInstalled(address indexed pool, IEulerSwap.Params params);
    event PoolUninstalled(address indexed pool);
    event WithdrawalExecuted(
        address indexed user,
        uint256 usdcAmount,
        uint256 wethAmount,
        uint256 wethDebt
    );
    event SubAccountCreated(address indexed user, address subAccount, uint256 nonce);

    // ============ Constructor ============

    constructor(
        IERC20 _usdc,
        IEulerSwapFactory _factory,
        IEVC _evc,
        IEVault _usdcVault,
        IEVault _wethVault,
        IERC20 _weth,
        address _owner
    ) 
        ERC4626(_usdc) 
        ERC20("Delta Neutral Vault", "DNV")
        Ownable(_owner)
    {
        factory = _factory;
        evc = _evc;
        usdcVault = _usdcVault;
        wethVault = _wethVault;
        weth = _weth;
        
        // Approve vaults for maximum efficiency
        _usdc.approve(address(_usdcVault), type(uint256).max);
        _weth.approve(address(_wethVault), type(uint256).max);
    }

    // ============ ERC4626 Overrides ============

    /// @notice Total assets are just USDC balance in this simple implementation
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Deposit USDC and keep in vault (no auto-deployment)
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // Prevent deposits if user is on their last available nonce
        require(userNonces[receiver] < 255, "Cannot deposit: user has reached sub-account limit");
        
        super._deposit(caller, receiver, assets, shares);
        // Assets stay in vault until rebalance is called
    }

    /// @notice Withdraw with automatic sub-account creation for user isolation
    /// @dev Creates sub-account automatically and transfers proportional position
    function withdrawToSubAccount(
        uint256 assets,
        address receiver,
        address owner,
        uint256[] calldata minOut, // [minUSDC, minWETH, maxWETHDebt]
        uint256 deadline
    ) external nonReentrant returns (uint256 shares, address userSubAccount) {
        require(block.timestamp <= deadline, "Deadline exceeded");
        require(minOut.length == 3, "Invalid minOut array");
        
        uint256 currentNonce = userNonces[receiver];
        
        // If on last nonce (255), mandate full withdrawal to prevent fund lockup
        if (currentNonce == 255) {
            uint256 userBalance = balanceOf(owner);
            require(assets == userBalance || assets >= userBalance, "Must withdraw all shares on final nonce");
            assets = userBalance; // Force full withdrawal
        }
        
        // Automatically create sub-account for user
        userSubAccount = _computeSubAccountAddress(receiver, currentNonce);
        
        // Uninstall current pool
        if (currentPool != address(0)) {
            factory.uninstallPool();
            currentPool = address(0);
        }

        // Calculate and validate proportional amounts (inline userPercentage)
        uint256 usdcAmount = (usdcVault.balanceOf(address(this)) * balanceOf(owner) * 1e18 / totalSupply()) / 1e18;
        require(usdcAmount >= minOut[0], "Insufficient USDC");
        
        uint256 wethAmount = (weth.balanceOf(address(this)) * balanceOf(owner) * 1e18 / totalSupply()) / 1e18;
        require(wethAmount >= minOut[1], "Insufficient WETH");
        
        uint256 wethDebt = (wethVault.debtOf(address(this)) * balanceOf(owner) * 1e18 / totalSupply()) / 1e18;
        require(wethDebt <= minOut[2], "Debt too high");

        // Transfer proportional position to user's sub-account
        _transferPositionToSubAccount(userSubAccount, usdcAmount, wethAmount, wethDebt);

        // Burn shares and increment nonce
        shares = previewWithdraw(assets);
        _burn(owner, shares);
        userNonces[receiver] = currentNonce + 1;

        // Reinstall pool if needed
        if (totalSupply() > 0 && lastParams.eulerAccount != address(0)) {
            _installPool(lastParams, lastInitialState, lastSalt);
        }

        emit SubAccountCreated(receiver, userSubAccount, currentNonce);
        emit WithdrawalExecuted(receiver, usdcAmount, wethAmount, wethDebt);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return (shares, userSubAccount);
    }

    /// @notice Preview what sub-account address will be used for next withdrawal
    /// @dev Useful for advanced users who want to prepare transactions
    function previewWithdrawalSubAccount(address user) external view returns (address) {
        uint256 nextNonce = userNonces[user];
        return _computeSubAccountAddress(user, nextNonce);
    }

    /// @notice Get user's current nonce usage for sub-accounts
    /// @dev Returns used nonces and remaining capacity (255 max usable, 256th is final)
    function getUserNonceInfo(address user) external view returns (uint256 used, uint256 remaining) {
        used = userNonces[user];
        remaining = used < 255 ? 255 - used : 0; // 255 is the last usable nonce
    }

    // ============ Internal Sub-Account Functions ============

    /// @notice Verify that a sub-account belongs to the specified user
    function _isUserSubAccount(address subAccount, address user) internal view returns (bool) {
        // Check if the sub-account has the same owner as the user
        // In EVC, sub-accounts share the first 19 bytes with their owner
        return _haveCommonOwner(subAccount, user);
    }

    /// @notice Check if two addresses have the same owner (share first 19 bytes)
    function _haveCommonOwner(address account1, address account2) internal pure returns (bool) {
        // XOR the addresses and check if difference is less than 256 (last byte)
        return (uint160(account1) ^ uint160(account2)) < 0x100;
    }

    /// @notice Compute sub-account address for a given owner and nonce
    function _computeSubAccountAddress(address owner, uint256 nonce) internal pure returns (address) {
        // Sub-account = owner address with last byte replaced by nonce
        require(nonce < 256, "Nonce too large");
        return address(uint160(owner) & uint160(0xFFFfFFfFfFFffFFfFFFffffFfFfFffFFfFFFFF00) | uint160(nonce));
    }

    /// @notice Get the next available nonce for a user's sub-account
    function _getNextUserNonce(address user) internal view returns (uint256) {
        return userNonces[user]; // Starts at 0, increments with each withdrawal
    }

    /// @notice Transfer proportional position to user's sub-account
    function _transferPositionToSubAccount(
        address userSubAccount,
        uint256 usdcAmount,
        uint256 wethAmount,
        uint256 wethDebt
    ) internal {
        // Enable necessary controllers on user's sub-account
        if (usdcAmount > 0) {
            // Enable USDC vault as collateral for the sub-account
            evc.call(
                address(usdcVault),
                userSubAccount,
                0,
                abi.encodeCall(IEVC.enableCollateral, (userSubAccount, address(usdcVault)))
            );
            
            // Transfer USDC collateral to user's sub-account
            usdcVault.transfer(userSubAccount, usdcAmount);
        }

        if (wethAmount > 0) {
            // Transfer WETH balance to user's sub-account
            weth.safeTransfer(userSubAccount, wethAmount);
        }

        if (wethDebt > 0) {
            // Enable WETH vault as controller for debt on the sub-account
            evc.call(
                address(wethVault),
                userSubAccount,
                0,
                abi.encodeCall(IEVC.enableController, (userSubAccount, address(wethVault)))
            );
            
            // Transfer debt to user's sub-account
            // This requires borrowing on behalf of the sub-account
            evc.call(
                address(wethVault),
                userSubAccount,
                0,
                abi.encodeCall(IBorrowing.borrow, (wethDebt, userSubAccount))
            );
            
            // Use the borrowed WETH to repay vault's debt
            IERC20(weth).transferFrom(userSubAccount, address(this), wethDebt);
            wethVault.repay(wethDebt, address(this));
        }
    }

    // ============ Rebalance Functions (OnlyOwner) ============

    /// @notice Install new EulerSwap pool with specified parameters
    function installPool(
        IEulerSwap.Params calldata params,
        IEulerSwap.InitialState calldata initialState,
        bytes32 salt
    ) external onlyOwner {
        require(currentPool == address(0), "Pool already installed");
        _installPool(params, initialState, salt);
    }

    /// @notice Uninstall current EulerSwap pool
    function uninstallPool() external onlyOwner {
        require(currentPool != address(0), "No pool installed");
        factory.uninstallPool();
        currentPool = address(0);
        emit PoolUninstalled(currentPool);
    }

    /// @notice Lend all available USDC to the USDC vault
    /// @dev Step 1 of delta-neutral strategy: Provide USDC as collateral
    function lendUsdc() external onlyOwner {
        uint256 usdcBalance = IERC20(asset()).balanceOf(address(this));
        require(usdcBalance > 0, "No USDC to lend");
        
        // Deposit USDC into the vault (becomes collateral)
        usdcVault.deposit(usdcBalance, address(this));
    }

    /// @notice Borrow WETH against USDC collateral
    /// @dev Step 2 of delta-neutral strategy: Borrow WETH using USDC as collateral
    /// @param wethAmount Amount of WETH to borrow
    function borrowWeth(uint256 wethAmount) external onlyOwner {
        require(wethAmount > 0, "Invalid borrow amount");
        
        // Enable USDC vault as collateral if not already enabled
        // This allows us to borrow against our USDC deposits
        try evc.isCollateralEnabled(address(this), address(usdcVault)) returns (bool enabled) {
            if (!enabled) {
                evc.enableCollateral(address(this), address(usdcVault));
            }
        } catch {
            // If the call fails, try to enable anyway (might already be enabled)
            evc.enableCollateral(address(this), address(usdcVault));
        }
        
        // Enable WETH vault as controller if not already enabled
        try evc.isControllerEnabled(address(this), address(wethVault)) returns (bool enabled) {
            if (!enabled) {
                evc.enableController(address(this), address(wethVault));
            }
        } catch {
            // If the call fails, try to enable anyway (might already be enabled)
            evc.enableController(address(this), address(wethVault));
        }
        
        // Borrow WETH from the vault
        wethVault.borrow(wethAmount, address(this));
    }

    /// @notice Repay WETH debt using available WETH balance
    /// @dev Step 3 of delta-neutral strategy: Repay borrowed WETH
    /// @param wethAmount Amount of WETH to repay (0 = repay all debt)
    function repayWeth(uint256 wethAmount) external onlyOwner {
        uint256 currentDebt = wethVault.debtOf(address(this));
        require(currentDebt > 0, "No debt to repay");
        
        // If amount is 0, repay all debt
        if (wethAmount == 0) {
            wethAmount = currentDebt;
        }
        
        // Ensure we don't try to repay more than we owe
        if (wethAmount > currentDebt) {
            wethAmount = currentDebt;
        }
        
        // Ensure we have enough WETH to repay
        uint256 wethBalance = weth.balanceOf(address(this));
        require(wethBalance >= wethAmount, "Insufficient WETH balance for repayment");
        
        // Repay the debt
        wethVault.repay(wethAmount, address(this));
    }

    /// @notice Lend WETH as collateral to WETH vault
    /// @dev Deposits available WETH into WETH vault as collateral
    function lendWeth() external onlyOwner {
        uint256 wethBalance = weth.balanceOf(address(this));
        require(wethBalance > 0, "No WETH to lend");
        
        // Enable WETH vault as collateral if not already enabled
        try evc.isCollateralEnabled(address(this), address(wethVault)) returns (bool enabled) {
            if (!enabled) {
                evc.enableCollateral(address(this), address(wethVault));
            }
        } catch {
            evc.enableCollateral(address(this), address(wethVault));
        }
        
        // Deposit WETH as collateral
        wethVault.deposit(wethBalance, address(this));
    }

    /// @notice Borrow USDC against collateral
    /// @dev Borrows specified amount of USDC from USDC vault
    /// @param usdcAmount Amount of USDC to borrow (0 = borrow max safe amount)
    function borrowUsdc(uint256 usdcAmount) external onlyOwner {
        require(usdcAmount > 0, "Invalid borrow amount");
        
        // Enable USDC vault as controller if not already enabled
        try evc.isControllerEnabled(address(this), address(usdcVault)) returns (bool enabled) {
            if (!enabled) {
                evc.enableController(address(this), address(usdcVault));
            }
        } catch {
            evc.enableController(address(this), address(usdcVault));
        }
        
        // Borrow USDC
        usdcVault.borrow(usdcAmount, address(this));
    }

    /// @notice Repay USDC debt
    /// @dev Repays USDC debt using available USDC balance
    /// @param usdcAmount Amount of USDC to repay (0 = repay all debt)
    function repayUsdc(uint256 usdcAmount) external onlyOwner {
        uint256 currentDebt = usdcVault.debtOf(address(this));
        require(currentDebt > 0, "No USDC debt to repay");
        
        // If amount is 0, repay all debt
        if (usdcAmount == 0) {
            usdcAmount = currentDebt;
        }
        
        // Don't repay more than current debt
        if (usdcAmount > currentDebt) {
            usdcAmount = currentDebt;
        }
        
        // Ensure we have enough USDC to repay
        uint256 usdcBalance = IERC20(asset()).balanceOf(address(this));
        require(usdcBalance >= usdcAmount, "Insufficient USDC balance for repayment");
        
        // Repay the debt
        usdcVault.repay(usdcAmount, address(this));
    }

    /// @notice Execute full rebalance: uninstall pool, rebalance positions, reinstall with new parameters
    /// @dev Complete strategy transition that handles pool management and position rebalancing
    /// @param usdcToLend Amount of USDC to lend as collateral (0 = don't lend any)
    /// @param targetWethBorrow Amount of WETH to borrow against collateral (0 = don't borrow any)
    /// @param wethToLend Amount of WETH to lend as collateral (0 = don't lend any)
    /// @param targetUsdcBorrow Amount of USDC to borrow against collateral (0 = don't borrow any)
    /// @param newParams New pool parameters for reinstallation
    /// @param newInitialState New initial state for pool reinstallation
    /// @param newSalt New salt for pool reinstallation
    function rebalance(
        uint256 usdcToLend,
        uint256 targetWethBorrow,
        uint256 wethToLend,
        uint256 targetUsdcBorrow,
        IEulerSwap.Params calldata newParams,
        IEulerSwap.InitialState calldata newInitialState,
        bytes32 newSalt
    ) external onlyOwner {
        // Step 1: Uninstall current pool if one exists
        if (currentPool != address(0)) {
            factory.uninstallPool();
            currentPool = address(0);
        }
        
        // Step 2: Lend specified amounts of USDC and/or WETH
        if (usdcToLend > 0) {
            uint256 usdcBalance = IERC20(asset()).balanceOf(address(this));
            require(usdcBalance >= usdcToLend, "Insufficient USDC balance");
            usdcVault.deposit(usdcToLend, address(this));
        }
        
        if (wethToLend > 0) {
            uint256 wethBalance = weth.balanceOf(address(this));
            require(wethBalance >= wethToLend, "Insufficient WETH balance");
            wethVault.deposit(wethToLend, address(this));
        }
        
        // Step 3: Enable collateral and controller based on strategy direction
        if (usdcToLend > 0) {
            // Enable USDC vault as collateral for lending USDC
            try evc.isCollateralEnabled(address(this), address(usdcVault)) returns (bool enabled) {
                if (!enabled) {
                    evc.enableCollateral(address(this), address(usdcVault));
                }
            } catch {
                evc.enableCollateral(address(this), address(usdcVault));
            }
        }
        
        if (wethToLend > 0) {
            // Enable WETH vault as collateral for lending WETH
            try evc.isCollateralEnabled(address(this), address(wethVault)) returns (bool enabled) {
                if (!enabled) {
                    evc.enableCollateral(address(this), address(wethVault));
                }
            } catch {
                evc.enableCollateral(address(this), address(wethVault));
            }
        }
        
        if (targetWethBorrow > 0) {
            // Enable WETH vault as controller for borrowing WETH
            try evc.isControllerEnabled(address(this), address(wethVault)) returns (bool enabled) {
                if (!enabled) {
                    evc.enableController(address(this), address(wethVault));
                }
            } catch {
                evc.enableController(address(this), address(wethVault));
            }
        }
        
        if (targetUsdcBorrow > 0) {
            // Enable USDC vault as controller for borrowing USDC
            try evc.isControllerEnabled(address(this), address(usdcVault)) returns (bool enabled) {
                if (!enabled) {
                    evc.enableController(address(this), address(usdcVault));
                }
            } catch {
                evc.enableController(address(this), address(usdcVault));
            }
        }
        
        // Step 4: Adjust positions to targets
        
        // Handle WETH borrowing/repayment
        if (targetWethBorrow > 0) {
            uint256 currentWethBalance = weth.balanceOf(address(this));
            uint256 currentWethDebt = wethVault.debtOf(address(this));
            
            if (targetWethBorrow > currentWethBalance) {
                // Need to borrow more WETH
                uint256 borrowAmount = targetWethBorrow - currentWethBalance;
                wethVault.borrow(borrowAmount, address(this));
            } else if (currentWethBalance > targetWethBorrow) {
                // Have excess WETH, use it to repay debt if any
                uint256 excessWeth = currentWethBalance - targetWethBorrow;
                if (currentWethDebt > 0) {
                    uint256 repayAmount = currentWethDebt < excessWeth ? currentWethDebt : excessWeth;
                    wethVault.repay(repayAmount, address(this));
                }
            }
        }
        
        // Handle USDC borrowing/repayment
        if (targetUsdcBorrow > 0) {
            uint256 currentUsdcBalance = IERC20(asset()).balanceOf(address(this));
            uint256 currentUsdcDebt = usdcVault.debtOf(address(this));
            
            if (targetUsdcBorrow > currentUsdcBalance) {
                // Need to borrow more USDC
                uint256 borrowAmount = targetUsdcBorrow - currentUsdcBalance;
                usdcVault.borrow(borrowAmount, address(this));
            } else if (currentUsdcBalance > targetUsdcBorrow) {
                // Have excess USDC, use it to repay debt if any
                uint256 excessUsdc = currentUsdcBalance - targetUsdcBorrow;
                if (currentUsdcDebt > 0) {
                    uint256 repayAmount = currentUsdcDebt < excessUsdc ? currentUsdcDebt : excessUsdc;
                    usdcVault.repay(repayAmount, address(this));
                }
            }
        }
        
        // Step 5: Reinstall pool with new parameters
        _installPool(newParams, newInitialState, newSalt);
    }



    // ============ Internal Functions ============

    function _installPool(
        IEulerSwap.Params memory params,
        IEulerSwap.InitialState memory initialState,
        bytes32 salt
    ) internal {
        currentPool = factory.deployPool(params, initialState, salt);
        
        // Store parameters for reinstalling
        lastParams = params;
        lastInitialState = initialState;
        lastSalt = salt;
        
        emit PoolInstalled(currentPool, params);
    }

    // ============ View Functions ============

    /// @notice Get current vault positions
    function getPositions() external view returns (
        uint256 usdcCollateral,
        uint256 wethBalance,
        uint256 wethDebt,
        address activePool
    ) {
        usdcCollateral = usdcVault.balanceOf(address(this));
        wethBalance = weth.balanceOf(address(this));
        wethDebt = wethVault.debtOf(address(this));
        activePool = currentPool;
    }

    /// @notice Calculate proportional withdrawal amounts for a user
    function previewProportionalWithdraw(address user) external view returns (
        uint256 usdcAmount,
        uint256 wethAmount,
        uint256 wethDebt
    ) {
        uint256 userShares = balanceOf(user);
        uint256 totalShares = totalSupply();
        
        if (totalShares == 0) return (0, 0, 0);
        
        uint256 userPercentage = (userShares * 1e18) / totalShares;
        
        usdcAmount = (usdcVault.balanceOf(address(this)) * userPercentage) / 1e18;
        wethAmount = (weth.balanceOf(address(this)) * userPercentage) / 1e18;
        wethDebt = (wethVault.debtOf(address(this)) * userPercentage) / 1e18;
    }
} 