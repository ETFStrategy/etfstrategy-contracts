// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TaxHook} from "../src/TaxHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Constants} from "./sepolia/Constants.sol";
import {Config} from "./sepolia/Config.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract DeployTaxHook is Script, Constants, Config {
    function run() external {
        // Load environment variables
        string memory rpcUrl = vm.envString("ETH_RPC_URL");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Create and select fork for the target network
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        // Treasury address - replace with your desired treasury address
        address treasury = address(0); // TODO: set treasury address
        uint160 startingPrice = 79228110147883812484826847210100;

        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Constructor arguments for TaxHook: (IPoolManager, IPunkStrategy, INFTStrategyFactory, address feeAddress)
        bytes memory constructorArgs = abi.encode(POOLMANAGER, treasury);

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(TaxHook).creationCode,
            constructorArgs
        );

        console.log("Computed hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        vm.startBroadcast(privateKey);

        // Deploy the TaxHook contract using CREATE2
        TaxHook taxHook = new TaxHook{salt: salt}(POOLMANAGER, treasury);
        require(
            address(taxHook) == hookAddress,
            "TaxHook: hook address mismatch"
        );

        PoolKey memory pool = PoolKey({
            currency0: CURRENCY0, // ETH (address(0))
            currency1: CURRENCY1, // token from config
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // Required for dynamic fee hooks
            tickSpacing: 60,
            hooks: IHooks(address(taxHook))
        });

        // Initialize the pool
        POOLMANAGER.initialize(pool, startingPrice);

        vm.stopBroadcast();

        console.log("TaxHook deployed at:", address(taxHook));
        console.log("Treasury address:", treasury);
        console.log("Pool Manager:", address(POOLMANAGER));
    }
}
