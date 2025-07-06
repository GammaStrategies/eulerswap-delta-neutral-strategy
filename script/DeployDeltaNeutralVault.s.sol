// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import {DeltaNeutralVault} from "../src/vault/DeltaNeutralVault.sol";
import {IEulerSwapFactory} from "../src/interfaces/IEulerSwapFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

contract DeployDeltaNeutralVault is Script {
    
    function run(
        address usdc,
        address weth,
        address eulerSwapFactory,
        address evc,
        address usdcVault,
        address wethVault
    ) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying DeltaNeutralVault with deployer:", deployer);
        console.log("USDC:", usdc);
        console.log("WETH:", weth);
        console.log("EulerSwap Factory:", eulerSwapFactory);
        console.log("EVC:", evc);
        console.log("USDC Vault:", usdcVault);
        console.log("WETH Vault:", wethVault);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the vault
        DeltaNeutralVault vault = new DeltaNeutralVault(
            IERC20(usdc),
            IEulerSwapFactory(eulerSwapFactory),
            IEVC(evc),
            IEVault(usdcVault),
            IEVault(wethVault),
            IERC20(weth),
            deployer // owner
        );

        vm.stopBroadcast();

        console.log("DeltaNeutralVault deployed at:", address(vault));
        console.log("Asset (USDC):", vault.asset());
        console.log("Name:", vault.name());
        console.log("Symbol:", vault.symbol());
        console.log("Owner:", vault.owner());
        
        // Example usage
        console.log("\nExample usage:");
        console.log("1. Users deposit USDC:");
        console.log("   vault.deposit(100000e6, user);");
        console.log("");
        console.log("2. Owner deploys to Euler:");
        console.log("   vault.deployToEuler();");
        console.log("");
        console.log("3. Owner installs curve:");
        console.log("   vault.installPool(params, initialState, salt);");
        console.log("");
        console.log("4. Users withdraw proportionally:");
        console.log("   vault.withdraw(amount, receiver, owner, minOut, deadline);");
    }
} 