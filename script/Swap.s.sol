// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "./sepolia/Constants.sol";
import {Config} from "./sepolia/Config.sol";

contract SwapScript is Script, Constants, Config {
    // slippage tolerance to allow for unlimited price impact
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    /////////////////////////////////////
    // --- Parameters to Configure --- //
    /////////////////////////////////////
    // Swap amount
    uint256 swapAmount = 0.02e18; // 0.1 ezETH

    // PoolSwapTest Contract address, sepolia
    PoolSwapTest swapRouter =
        PoolSwapTest(0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe);

    // --- pool configuration --- //
    // fees paid by swappers that accrue to liquidity providers

    int24 tickSpacing = 60;

    address caller = address(1111);

    function run() external {
        string memory rpcUrl = vm.envString("ETH_RPC_URL");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Create and select fork for the target network
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);
        vm.startBroadcast(privateKey);

        buyToken();
        sellToken();

        vm.stopBroadcast();
    }

    function buyToken() public {
        PoolKey memory pool = PoolKey({
            currency0: CURRENCY0,
            currency1: CURRENCY1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: HOOK_CONTRACT
        });

        // approve tokens to the swap router
        if (!CURRENCY0.isAddressZero()) {
            TOKEN0.approve(address(swapRouter), swapAmount);
        }
        if (
            !CURRENCY1.isAddressZero() &&
            TOKEN1.allowance(caller, address(swapRouter)) < swapAmount
        ) {
            TOKEN1.approve(address(swapRouter), swapAmount);
        }

        // ------------------------------ //
        // Swap 100e18 token0 into token1 //
        // ------------------------------ //
        bool zeroForOne = true;
        int256 amount = int256(swapAmount);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: zeroForOne ? -amount : amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
        });

        // in v4, users have the option to receieve native ERC20s or wrapped ERC1155 tokens
        // here, we'll take the ERC20s
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes memory hookData = new bytes(0);
        zeroForOne
            ? swapRouter.swap{value: uint256(amount)}(
                pool,
                params,
                testSettings,
                hookData
            )
            : swapRouter.swap(pool, params, testSettings, hookData);
    }

    function sellToken() public {
        PoolKey memory pool = PoolKey({
            currency0: CURRENCY0,
            currency1: CURRENCY1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: HOOK_CONTRACT
        });

        // approve tokens to the swap router
        if (!CURRENCY1.isAddressZero()) {
            TOKEN1.approve(address(swapRouter), type(uint256).max);
        }
        if (
            !CURRENCY0.isAddressZero() &&
            TOKEN0.allowance(caller, address(swapRouter)) < swapAmount
        ) {
            TOKEN0.approve(address(swapRouter), type(uint256).max);
        }

        // ------------------------------ //
        // Swap token1 back to token0 (sell) //
        // ------------------------------ //
        bool zeroForOne = false; // selling token1 for token0
        int256 amount = int256(swapAmount);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: zeroForOne ? -amount : amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
        });

        // in v4, users have the option to receieve native ERC20s or wrapped ERC1155 tokens
        // here, we'll take the ERC20s
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes memory hookData = new bytes(0);
        swapRouter.swap(pool, params, testSettings, hookData);
    }
}
