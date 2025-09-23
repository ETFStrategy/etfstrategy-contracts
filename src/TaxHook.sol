// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

contract TaxHook is BaseHook {
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeCast for int128;

    uint256 public constant HOOK_FEE_PERCENTAGE = 10000; // 10% fee
    uint256 public constant FEE_DENOMINATOR = 100000;

    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    address public feeAddress;

    constructor(IPoolManager _poolManager, address _feeAddress) BaseHook(_poolManager) {
        feeAddress = _feeAddress;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) =
            (specifiedTokenIs0) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());

        if (swapAmount < 0) swapAmount = -swapAmount;

        bool isEthFee = Currency.unwrap(feeCurrency) == address(0);

        uint256 feeAmount = uint128(swapAmount) * HOOK_FEE_PERCENTAGE / FEE_DENOMINATOR;

        if (feeAmount == 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        poolManager.take(feeCurrency, address(this), feeAmount);

        // Handle fee token deposit or conversion
        if (!isEthFee) {
            uint256 feeInEth = _swapToEth(key, feeAmount);
            _processFees(feeInEth);
        } else {
            // Fee amount is in ETH
            _processFees(feeAmount);
        }
        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }

    function updateFeeAddress(address newFeeAddress) external {
        require(msg.sender == feeAddress, "TaxHook: only fee address can update");
        require(newFeeAddress != address(0), "TaxHook: new fee address cannot be zero");
        feeAddress = newFeeAddress;
    }

    function _swapToEth(PoolKey memory key, uint256 amount) internal returns (uint256) {
        uint256 ethBefore = address(this).balance;

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            bytes("")
        );

        // Handle token settlements
        if (delta.amount0() < 0) {
            key.currency0.settle(poolManager, address(this), uint256(int256(-delta.amount0())), false);
        } else if (delta.amount0() > 0) {
            key.currency0.take(poolManager, address(this), uint256(int256(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            key.currency1.settle(poolManager, address(this), uint256(int256(-delta.amount1())), false);
        } else if (delta.amount1() > 0) {
            key.currency1.take(poolManager, address(this), uint256(int256(delta.amount1())), false);
        }

        return address(this).balance - ethBefore;
    }

    function _processFees(uint256 feeAmount) internal {
        if (feeAmount == 0) return;
        SafeTransferLib.forceSafeTransferETH(feeAddress, feeAmount);
    }

    // receive function to accept ETH fees
    receive() external payable {}
}
