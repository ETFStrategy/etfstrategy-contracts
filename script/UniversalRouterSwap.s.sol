// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Constants} from "./sepolia/Constants.sol";
import {Config} from "./sepolia/Config.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

contract UniversalRouterSwapScript is Script, Constants, Config {
    // Universal Router address on Sepolia testnet
    IUniversalRouter public constant UNIVERSAL_ROUTER = IUniversalRouter(0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b);

    // Universal Router Commands
    uint8 public constant V4_SWAP = 0x10;

    // Swap parameters
    uint256 swapAmount = 0.02e18; // 0.02 ETH
    int24 tickSpacing = 60;
    address caller = address(3333);

    function run() external {
        string memory rpcUrl = vm.envString("ETH_RPC_URL");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Create and select fork for the target network
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);
        vm.startBroadcast(privateKey);

        swapViaUniversalRouter();

        vm.stopBroadcast();
    }

    function swapViaUniversalRouter() public {
        // Define the pool key
        PoolKey memory pool = PoolKey({
            currency0: CURRENCY0,
            currency1: CURRENCY1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // Approve tokens to the Universal Router
        if (!CURRENCY0.isAddressZero()) {
            TOKEN0.approve(address(UNIVERSAL_ROUTER), swapAmount);
        }
        if (!CURRENCY1.isAddressZero()) {
            TOKEN1.approve(address(UNIVERSAL_ROUTER), swapAmount);
        }

        // Encode V4 swap actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),  // 0x06
            uint8(Actions.SETTLE_ALL),            // 0x0c
            uint8(Actions.TAKE_ALL)               // 0x0f
        );

        // Encode swap parameters for SWAP_EXACT_IN_SINGLE
        bytes memory swapParams = abi.encode(
            pool,                    // PoolKey
            true,                    // zeroForOne (swap token0 for token1)
            uint128(swapAmount),     // amountIn
            uint128(0),              // amountOutMinimum (0 for demo - dangerous in production!)
            TickMath.MIN_SQRT_PRICE + 1  // sqrtPriceLimitX96
        );

        // Encode SETTLE_ALL parameters (settle currency0)
        bytes memory settleParams = abi.encode(
            CURRENCY0,              // Currency to settle
            uint256(swapAmount)     // Amount to settle
        );

        // Encode TAKE_ALL parameters (take currency1)
        bytes memory takeParams = abi.encode(
            CURRENCY1,              // Currency to take
            ActionConstants.MSG_SENDER  // Recipient
        );

        // Package all parameters
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = swapParams;
        inputs[1] = settleParams;
        inputs[2] = takeParams;

        // Encode Universal Router command
        bytes memory commands = abi.encodePacked(V4_SWAP);

        // Execute swap via Universal Router
        uint256 deadline = block.timestamp + 300; // 5 minutes from now

        console.log("=== Universal Router V4 Swap ===");
        console.log("Pool Currency0:", Currency.unwrap(pool.currency0));
        console.log("Pool Currency1:", Currency.unwrap(pool.currency1));
        console.log("Swap Amount:", swapAmount);
        console.log("Universal Router:", address(UNIVERSAL_ROUTER));
        console.log("Commands length:", commands.length);
        console.log("Actions length:", actions.length);

        // Encode the complete input for V4_SWAP command
        bytes memory v4SwapInput = abi.encode(actions, inputs);
        bytes[] memory finalInputs = new bytes[](1);
        finalInputs[0] = v4SwapInput;

        if (CURRENCY0.isAddressZero()) {
            // If currency0 is ETH, send ETH value
            UNIVERSAL_ROUTER.execute{value: swapAmount}(commands, finalInputs, deadline);
        } else {
            UNIVERSAL_ROUTER.execute(commands, finalInputs, deadline);
        }

        console.log("Universal Router swap completed!");
    }
}