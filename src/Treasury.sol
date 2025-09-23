// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IV3SwapRouter} from "./interfaces/IV3SwapRouter.sol";
import {IQuoterV2} from "./interfaces/IQuoterV2.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

// Interface for burnable tokens
interface IBurnable {
    function burn(uint256 amount) external;
}

contract Treasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    IV3SwapRouter public constant v3Router =
        IV3SwapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    IQuoterV2 public constant v3Quoter =
        IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e);

    // V4 constants - Real Mainnet addresses
    IPoolManager public constant v4PoolManager =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90); // V4 PoolManager Mainnet
    IV4Router public constant v4Router =
        IV4Router(0x00000000000044a361Ae3cAc094c9D1b14Eece97); // V4Router Mainnet

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public buyBackToken;
    PoolKey public buyBackPoolKey; // V4 pool key for buyback

    // Order Status
    enum OrderStatus {
        BUYING,
        SELLING,
        SUCCESS
    }

    // Order struct
    struct Order {
        uint256 id;
        address token;
        uint256 ethSpent;
        uint256 tokenAmount;
        uint256 buyPrice;
        uint256 targetSellPrice;
        uint256 buyTimestamp;
        uint256 sellTimestamp;
        OrderStatus status;
    }

    // Configuration
    uint256 public amountPerOrder = 10 * 1e9; // 10 WSOL (9 decimals)
    uint256 public minPnlPercent = 10;
    address public targetToken;
    uint24 public poolFee = 3000; // For V3
    uint256 public callerReward = 0.005 ether; // Reward for function callers

    // State
    uint256 public currentOrderId = 1;
    mapping(uint256 => Order) public orders;

    // Events
    event OrderBought(
        uint256 indexed orderId,
        uint256 ethSpent,
        uint256 tokenReceived,
        uint256 buyPrice
    );
    event OrderSold(
        uint256 indexed orderId,
        uint256 ethReceived,
        uint256 profit
    );
    event ConfigUpdated(
        address token,
        uint256 amountPerOrder,
        uint256 minPNLPercent,
        uint24 poolFee,
        uint256 callerReward
    );
    event BuyBackExecuted(
        uint256 indexed orderId,
        uint256 ethUsed,
        uint256 buyBackTokenReceived
    );
    event TokensBurned(uint256 indexed orderId, uint256 amount);
    event CallerRewarded(address indexed caller, uint256 amount, string action);

    constructor(
        address _initialOwner,
        address _token,
        uint256 _amountPerOrder,
        uint256 _minPNLPercent,
        address _buyBackToken,
        uint24 _poolFee,
        uint256 _callerReward,
        PoolKey memory _buyBackPoolKey
    ) Ownable(_initialOwner) {
        require(_token != address(0), "Invalid token");
        require(_amountPerOrder > 0, "Invalid amount");
        require(_minPNLPercent > 0 && _minPNLPercent <= 100, "Invalid PNL");
        require(_callerReward <= 1 ether, "Caller reward too high");

        targetToken = _token;
        amountPerOrder = _amountPerOrder;
        minPnlPercent = _minPNLPercent;
        poolFee = _poolFee;
        callerReward = _callerReward;
        buyBackToken = _buyBackToken;
        buyBackPoolKey = _buyBackPoolKey;

        emit ConfigUpdated(
            _token,
            _amountPerOrder,
            _minPNLPercent,
            _poolFee,
            _callerReward
        );
    }

    /**
     * @dev Receive ETH
     */
    receive() external payable {}

    /**
     * @dev Buy tokens for current order (public function with caller reward)
     */
    function buy() external nonReentrant {
        require(targetToken != address(0), "Token not configured");
        require(amountPerOrder > 0, "Amount not configured");

        // Get current order
        Order storage order = orders[currentOrderId];
        require(
            order.status == OrderStatus.BUYING || order.id == 0,
            "Order not in BUYING status"
        );

        // Use quoter to estimate required ETH
        (uint256 estimatedETH, , , ) = v3Quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: WETH,
                tokenOut: targetToken,
                amountOut: amountPerOrder,
                fee: poolFee,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 maxETHForSwap = estimatedETH * 103 / 100; // 3% slippage tolerance

        // Check total required ETH (swap + caller reward)
        uint256 totalRequired = maxETHForSwap + callerReward;
        require(address(this).balance >= totalRequired, "Insufficient ETH balance");

        // Get token balance before swap
        uint256 tokenBalanceBefore = IERC20(targetToken).balanceOf(address(this));

        // Execute swap for exact output
        uint256 actualETHSpent = _buyOrder(maxETHForSwap);

        // Verify we received exactly amountPerOrder tokens
        uint256 tokenBalanceAfter = IERC20(targetToken).balanceOf(address(this));
        uint256 tokensReceived = tokenBalanceAfter - tokenBalanceBefore;
        require(tokensReceived == amountPerOrder, "Swap output mismatch");


        // Calculate prices based on actual ETH spent
        // buyPrice in wei per WSOL unit (amountPerOrder is in 1e9 scale for WSOL)
        uint256 buyPrice = (actualETHSpent * 1e9) / amountPerOrder;
        uint256 targetSellPrice = (buyPrice * (100 + minPnlPercent)) / 100;

        // Update current order
        order.id = currentOrderId;
        order.token = targetToken;
        order.ethSpent = actualETHSpent;
        order.tokenAmount = tokensReceived;
        order.buyPrice = buyPrice;
        order.targetSellPrice = targetSellPrice;
        order.buyTimestamp = block.timestamp;
        order.status = OrderStatus.SELLING;

        emit OrderBought(currentOrderId, actualETHSpent, tokensReceived, buyPrice);

        // Create new order with BUYING status
        currentOrderId++;
        orders[currentOrderId].status = OrderStatus.BUYING;

        // Reward the caller immediately (nonReentrant modifier protects against reentrancy)
        (bool success, ) = payable(msg.sender).call{value: callerReward}("");
        require(success, "Caller reward transfer failed");
        emit CallerRewarded(msg.sender, callerReward, "buy");
    }

    /**
     * @dev Sell tokens for specific order (public function with caller reward)
     */
    function sell(uint256 orderId) external nonReentrant {
        require(buyBackToken != address(0), "BuyBack token not configured");

        Order storage order = orders[orderId];
        require(order.id == orderId, "Invalid order ID");
        require(
            order.status == OrderStatus.SELLING,
            "Order not in SELLING status"
        );

        // Execute swap for exact input with target profit
        uint256 ethReceived = _takeProfit(
            order.tokenAmount,
            order.ethSpent,
            minPnlPercent
        );

        // Calculate profit
        uint256 profit = ethReceived > order.ethSpent
            ? ethReceived - order.ethSpent
            : 0;

        // Update order status
        order.sellTimestamp = block.timestamp;
        order.status = OrderStatus.SUCCESS;

        emit OrderSold(orderId, ethReceived, profit);

        // Reserve caller reward from received ETH
        uint256 callerRewardAmount = ethReceived >= callerReward
            ? callerReward
            : 0;
        uint256 ethForBuyback = ethReceived > callerRewardAmount
            ? ethReceived - callerRewardAmount
            : 0;

        // Use remaining ETH to buy back buyBackToken
        if (ethForBuyback > 0) {
            // Execute buyback and burn
            _buyBackAndBurn(ethForBuyback, orderId);
        }

        // Reward the caller immediately (nonReentrant modifier protects against reentrancy)
        if (callerRewardAmount > 0) {
            (bool success, ) = payable(msg.sender).call{value: callerRewardAmount}("");
            require(success, "Caller reward transfer failed");
            emit CallerRewarded(msg.sender, callerRewardAmount, "sell");
        }
    }

    function _buyOrder(
        uint256 amountInMaximum
    ) internal returns (uint256 amountIn) {
        // Wrap ETH to WETH
        IWETH9(WETH).deposit{value: amountInMaximum}();

        // Approve router to spend WETH
        IERC20(WETH).safeIncreaseAllowance(address(v3Router), amountInMaximum);

        IV3SwapRouter.ExactOutputSingleParams memory params = IV3SwapRouter
            .ExactOutputSingleParams({
                tokenIn: WETH,
                tokenOut: targetToken,
                fee: poolFee,
                recipient: address(this),
                amountOut: amountPerOrder,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: 0
            });

        amountIn = v3Router.exactOutputSingle(params);

        // Unwrap any remaining WETH back to ETH
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        if (wethBalance > 0) {
            IWETH9(WETH).withdraw(wethBalance);
        }
    }

    function _takeProfit(
        uint256 tokenAmount,
        uint256 originalEthSpent,
        uint256 targetPnlPercent
    ) internal returns (uint256) {
        // Calculate minimum ETH to receive for target profit
        uint256 minETHRequired = (originalEthSpent * (100 + targetPnlPercent)) /
            100;

        // Approve router to spend tokens using SafeERC20
        IERC20(targetToken).safeIncreaseAllowance(
            address(v3Router),
            tokenAmount
        );

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter
            .ExactInputSingleParams({
                tokenIn: targetToken,
                tokenOut: WETH,
                fee: poolFee,
                recipient: address(this),
                amountIn: tokenAmount,
                amountOutMinimum: minETHRequired, // Ensure minimum profit
                sqrtPriceLimitX96: 0
            });

        uint256 amountOut = v3Router.exactInputSingle(params);
        IWETH9(WETH).withdraw(amountOut);

        // Verify that we achieved the minimum profit
        require(amountOut >= minETHRequired, "Insufficient profit achieved");

        return amountOut;
    }

    /**
     * @dev Buy back buyBackToken with ETH and burn it
     */
    function _buyBackAndBurn(uint256 ethAmount, uint256 orderId) internal {
        require(ethAmount > 0, "No ETH to buy back");
        require(buyBackToken != address(0), "BuyBack token not set");

        // Execute buyback swap directly
        uint256 actualTokensReceived = _executeBuyBack(ethAmount);

        emit BuyBackExecuted(orderId, ethAmount, actualTokensReceived);

        // Burn the buyback tokens
        if (actualTokensReceived > 0) {
            IBurnable(buyBackToken).burn(actualTokensReceived);
            emit TokensBurned(orderId, actualTokensReceived);
        }
    }


    /**
     * @dev Execute buyback swap using V4Router directly
     */
    function _executeBuyBack(uint256 ethAmount) internal returns (uint256) {
        require(ethAmount > 0, "No ETH to buy back");
        require(buyBackToken != address(0), "BuyBack token not set");

        // Wrap ETH to WETH first
        IWETH9(WETH).deposit{value: ethAmount}();

        // Approve V4Router to spend WETH
        IERC20(WETH).safeIncreaseAllowance(address(v4Router), ethAmount);

        // Use the existing buyBackPoolKey (WETH/MockToken from test setup)
        // Determine swap direction based on the pool configuration
        bool zeroForOne = buyBackPoolKey.currency0 == Currency.wrap(WETH);

        // Execute V4 swap directly - no complex encoding needed!
        uint256 amountOut = v4Router.swapExactTokensForTokens(
            ethAmount,                  // amountIn
            0,                         // amountOutMin (accept any amount)
            zeroForOne,                // swap direction
            buyBackPoolKey,            // pool identification (uses existing WETH/MockToken pool)
            "",                        // hookData (empty)
            address(this),             // recipient (this contract)
            block.timestamp + 300      // deadline (5 minutes)
        );

        // Calculate tokens received
        return amountOut;
    }


    /**
     * @dev Get order details
     */
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /**
     * @dev Emergency withdraw ETH
     */
    function emergencyWithdrawETH(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        (bool success, ) = owner().call{value: amount}("");
        require(success, "Transfer failed");
    }

    /**
     * @dev Emergency withdraw tokens
     */
    function emergencyWithdrawToken(
        address token,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @dev Get balances
     */
    function getBalances()
        external
        view
        returns (uint256 ethBalance, uint256 tokenBalance)
    {
        ethBalance = address(this).balance;
        if (targetToken != address(0)) {
            tokenBalance = IERC20(targetToken).balanceOf(address(this));
        }
        return (ethBalance, tokenBalance);
    }

    /**
     * @dev Get configuration details
     */
    function getConfig()
        external
        view
        returns (
            address token,
            uint256 amount,
            uint256 minPnl,
            address buyBack,
            uint24 fee,
            uint256 reward
        )
    {
        return (
            targetToken,
            amountPerOrder,
            minPnlPercent,
            buyBackToken,
            poolFee,
            callerReward
        );
    }

    /**
     * @dev Update caller reward (only owner can call)
     */
    function updateCallerReward(uint256 _newCallerReward) external onlyOwner {
        require(_newCallerReward <= 1 ether, "Caller reward too high");

        callerReward = _newCallerReward;

        emit ConfigUpdated(
            targetToken,
            amountPerOrder,
            minPnlPercent,
            poolFee,
            _newCallerReward
        );
    }
}
