// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Router token swapping functionality for Uniswap V3
/// @notice Functions for swapping tokens via Uniswap V3 with extended functionality
interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external payable returns (uint256 amountIn);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    function exactInput(ExactInputParams calldata params)
        external payable returns (uint256 amountOut);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path
    function exactOutput(ExactOutputParams calldata params)
        external payable returns (uint256 amountIn);

    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);

    /// @notice Refunds any ETH balance held by this contract to the `msg.sender`
    function refundETH() external payable;
}