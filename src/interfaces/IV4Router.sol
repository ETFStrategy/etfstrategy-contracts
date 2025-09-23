// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IV4Router {
    /// @notice Swaps exact amount of tokens for tokens
    /// @param amountIn The amount of input tokens to swap
    /// @param amountOutMin The minimum amount of output tokens expected
    /// @param zeroForOne Direction of the swap (true if swapping token0 for token1)
    /// @param poolKey The pool key identifying the pool
    /// @param hookData Additional data for hooks
    /// @param to Address to receive the output tokens
    /// @param deadline Transaction deadline
    /// @return amountOut The amount of output tokens received
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        PoolKey calldata poolKey,
        bytes calldata hookData,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
}