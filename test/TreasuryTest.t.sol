// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

// Uniswap V3 interfaces for liquidity
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(
        MintParams calldata params
    )
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );
}

interface IUniswapV3Factory {
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool);
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
}

contract TreasuryTestNew is Test {
    using CurrencyLibrary for Currency;

    Treasury public treasury;
    MockERC20 public mockToken; // buyBackToken
    PoolKey public mockTokenV4PoolKey; // V4 pool key for MockToken/WETH

    // Real Mainnet addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSOL = 0xD31a59c85aE9D8edEFeC411D448f90841571b89c; // target token
    address constant UNISWAP_V3_FACTORY =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant NONFUNGIBLE_POSITION_MANAGER =
        0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    IV3SwapRouter constant v3Router = IV3SwapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);

    // V4 constants - Real Mainnet addresses
    IPoolManager constant V4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // Test parameters
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address liquidityProvider = makeAddr("liquidityProvider");
    address marketMaker = makeAddr("marketMaker");

    uint256 constant AMOUNT_PER_ORDER = 1 * 1e9; // 1 WSOL (9 decimals) - smaller for testing
    uint256 constant MIN_PNL_PERCENT = 10; // 10% minimum profit for high profit testing
    uint24 constant POOL_FEE = 3000; // 0.3%
    uint256 constant CALLER_REWARD = 0.001 ether; // 0.001 ETH

    string mainnetRpcUrl = vm.envString("MAINNET_RPC_URL");
    uint256 mainnetFork;

    function setUp() public {
        mainnetFork = vm.createFork(mainnetRpcUrl);
        vm.selectFork(mainnetFork);

        console.log("=== Treasury Test Setup with WSOL and MockERC20 ===");

        // Deploy MockERC20 as buyBackToken
        vm.startPrank(owner);
        mockToken = new MockERC20();
        vm.stopPrank();

        console.log("MockERC20 deployed at:", address(mockToken));
        console.log(
            "MockERC20 total supply:",
            mockToken.totalSupply() / 1e18,
            "tokens"
        );

        // Setup liquidity for pools (V3 for WSOL, V3 for MockToken mock V4 pool)
        _setupLiquidity();

        // Create V4 pool key for MockToken/WETH buyback
        mockTokenV4PoolKey = _createMockTokenV4PoolKey();

        // Deploy Treasury with V4 configuration
        vm.startPrank(owner);
        treasury = new Treasury(
            owner,
            WSOL, // target token
            AMOUNT_PER_ORDER,
            MIN_PNL_PERCENT,
            address(mockToken), // buyback token
            POOL_FEE,
            CALLER_REWARD,
            mockTokenV4PoolKey // V4 pool key for buyback
        );
        vm.stopPrank();

        // Fund treasury with ETH for testing
        vm.deal(address(treasury), 50 ether);

        // Fund users with ETH for gas
        vm.deal(user1, 1 ether);
        vm.deal(user2, 1 ether);

        // Fund market maker with very large amount of ETH for aggressive price manipulation
        vm.deal(marketMaker, 500 ether);

        console.log("Treasury deployed at:", address(treasury));
        console.log(
            "Treasury ETH balance:",
            address(treasury).balance / 1e18,
            "ETH"
        );
        console.log("Target token (WSOL):", WSOL);
        console.log("Buyback token (MockERC20):", address(mockToken));
        console.log("Amount per order:", AMOUNT_PER_ORDER / 1e9, "WSOL");
        console.log(
            "Amount per order from contract:",
            treasury.amountPerOrder() / 1e9,
            "WSOL"
        );

        // Initialize V4 pool for buyback directly in test
        PoolKey memory buyBackPoolKey = _createMockTokenV4PoolKey();
        IPoolManager v4PoolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        v4PoolManager.initialize(buyBackPoolKey, 792281625142643375935439503360); // sqrt(0.001) * 2^96
        console.log("V4 pool initialized for buyback");
    }

    function _setupLiquidity() internal {
        console.log("=== Setting up liquidity ===");

        vm.deal(liquidityProvider, 100 ether);

        // Transfer MockERC20 tokens to liquidity provider for adding liquidity
        vm.prank(owner);
        mockToken.transfer(liquidityProvider, 50000 * 1e18);

        vm.startPrank(liquidityProvider);

        // Create pools if they don't exist
        IUniswapV3Factory factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);

        // Check if WSOL/WETH pool exists
        address wsolWethPool = factory.getPool(WSOL, WETH, POOL_FEE);
        console.log("WSOL/WETH pool:", wsolWethPool);

        // Check if MockToken/WETH pool exists
        address mockWethPool = factory.getPool(
            address(mockToken),
            WETH,
            POOL_FEE
        );
        if (mockWethPool == address(0)) {
            console.log("Creating MockToken/WETH pool...");
            mockWethPool = factory.createPool(
                address(mockToken),
                WETH,
                POOL_FEE
            );
            console.log("MockToken/WETH pool created:", mockWethPool);

            // Initialize the pool with proper liquidity
            _initializeMockTokenPool(mockWethPool);
        } else {
            console.log("MockToken/WETH pool exists:", mockWethPool);
        }

        vm.stopPrank();

        console.log("Liquidity setup completed");
    }

    function _initializeMockTokenPool(address pool) internal {
        console.log("Initializing MockToken/WETH pool with liquidity...");

        // Initialize pool with 1:1000 price (1 WETH = 1000 MockToken)
        // sqrtPriceX96 = sqrt(price) * 2^96
        // For 1:1000 ratio: sqrt(1000) * 2^96 = 31.622... * 2^96
        uint160 sqrtPriceX96;
        if (address(mockToken) < WETH) {
            // MockToken is token0, so price = token1/token0 = WETH/MockToken = 1/1000 = 0.001
            // sqrt(0.001) * 2^96 ≈ 2.508e21
            sqrtPriceX96 = 2508287737696256;
        } else {
            // WETH is token0, so price = token1/token0 = MockToken/WETH = 1000
            // sqrt(1000) * 2^96 ≈ 2.508e24
            sqrtPriceX96 = 2508287737696256000;
        }

        IUniswapV3Pool(pool).initialize(sqrtPriceX96);

        // Wrap ETH to WETH for liquidity provision
        IWETH9(WETH).deposit{value: 10 ether}();

        // Approve tokens for position manager
        IERC20(WETH).approve(NONFUNGIBLE_POSITION_MANAGER, 10 ether);
        mockToken.approve(NONFUNGIBLE_POSITION_MANAGER, 10000 * 1e18);

        // Create initial liquidity position (1:1000 ratio - 1 WETH = 1000 MockToken)
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(mockToken) < WETH ? address(mockToken) : WETH,
            token1: address(mockToken) < WETH ? WETH : address(mockToken),
            fee: POOL_FEE,
            tickLower: -887220, // Full range liquidity
            tickUpper: 887220,  // Full range liquidity
            amount0Desired: address(mockToken) < WETH ? 10000 * 1e18 : 10 ether,
            amount1Desired: address(mockToken) < WETH ? 10 ether : 10000 * 1e18,
            amount0Min: 0,
            amount1Min: 0,
            recipient: liquidityProvider,
            deadline: block.timestamp + 1 hours
        });

        INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).mint(params);
        console.log("MockToken/WETH pool initialized with liquidity");
    }

    function _createMockTokenV4PoolKey() internal view returns (PoolKey memory) {
        // Create V4 pool key for MockToken/WETH
        Currency currency0;
        Currency currency1;

        if (address(mockToken) < WETH) {
            currency0 = Currency.wrap(address(mockToken));
            currency1 = Currency.wrap(WETH);
        } else {
            currency0 = Currency.wrap(WETH);
            currency1 = Currency.wrap(address(mockToken));
        }

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0)) // No hooks
        });
    }


    function test_Buy() public {
        console.log("\n=== Test Buy Function ===");

        // Execute buy
        vm.prank(user1);
        treasury.buy();

        // Check results
        uint256 treasuryBalanceAfter = address(treasury).balance;
        uint256 user1BalanceAfter = user1.balance;
        uint256 wsolBalance = IERC20(WSOL).balanceOf(address(treasury));

        console.log(
            "Treasury balance after:",
            treasuryBalanceAfter / 1e18,
            "ETH"
        );
        console.log("User1 balance after:", user1BalanceAfter / 1e18, "ETH");
        console.log("Treasury WSOL balance:", wsolBalance / 1e9, "WSOL");

        // Get order details
        Treasury.Order memory order = treasury.getOrder(1);
        console.log("Order ID:", order.id);
        console.log("ETH spent:", order.ethSpent / 1e18, "ETH");
        console.log("Token amount:", order.tokenAmount / 1e9, "WSOL");
        console.log("Buy price (wei per WSOL unit):", order.buyPrice);

        console.log("SUCCESS: Buy test completed successfully");
    }

    function testBuyAndSellSequence() public {
        console.log("\n=== Test Buy and Sell Sequence ===");

        uint256 initialTreasuryBalance = address(treasury).balance;
        console.log(
            "Initial treasury balance:",
            initialTreasuryBalance / 1e18,
            "ETH"
        );

        // Buy
        vm.prank(user1);
        treasury.buy();

        uint256 afterBuyBalance = address(treasury).balance;
        uint256 wsolBalance = IERC20(WSOL).balanceOf(address(treasury));
        console.log("After buy - Treasury ETH (exact):", afterBuyBalance, "wei");
        console.log("After buy - Treasury ETH (display):", afterBuyBalance / 1e18, "ETH");
        console.log("ETH spent on buy:", initialTreasuryBalance - afterBuyBalance, "wei");
        console.log("ETH spent on buy (display):", (initialTreasuryBalance - afterBuyBalance) / 1e18, "ETH");
        console.log("After buy - Treasury WSOL:", wsolBalance / 1e9, "WSOL");

        // Check current WSOL/ETH price
        address wsolWethPool = 0x127452F3f9cDc0389b0Bf59ce6131aA3Bd763598;
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(wsolWethPool).slot0();

        // Calculate actual price: price = (sqrtPriceX96 / 2^96)^2
        // For WSOL/WETH pool, price = WETH per WSOL
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) / (2**192);
        uint256 wsolPerEth = 1e18 / price; // How many WSOL for 1 ETH

        console.log("Current WSOL/ETH pool sqrtPriceX96:", sqrtPriceX96);
        console.log("Current price (WETH per WSOL):", price);
        console.log("Current rate: 1 ETH =", wsolPerEth / 1e9, "WSOL");

        // Wait and then market maker will manipulate price
        vm.warp(block.timestamp + 2 hours);

        console.log("=== Market Maker Price Manipulation ===");

        // Market maker buys large amount of WSOL to push price up
        vm.startPrank(marketMaker);

        console.log("Market maker ETH balance:", marketMaker.balance / 1e18, "ETH");

        // Wrap massive amount of ETH to WETH for aggressive price manipulation
        IWETH9(WETH).deposit{value: 200 ether}();
        console.log("Wrapped 200 ETH to WETH for aggressive pump");

        // Approve router
        IERC20(WETH).approve(address(v3Router), 200 ether);

        console.log("=== AGGRESSIVE PRICE PUMP FOR 10%+ PROFIT ===");

        // Execute multiple large WSOL buys to aggressively pump price
        console.log("Executing first massive WSOL buy...");

        IV3SwapRouter.ExactInputSingleParams memory buyParams1 = IV3SwapRouter
            .ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: WSOL,
                fee: POOL_FEE,
                recipient: marketMaker,
                amountIn: 80 ether, // Massive purchase to move market significantly
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        uint256 wsolReceived1 = v3Router.exactInputSingle(buyParams1);
        console.log("First buy: Market maker bought", wsolReceived1 / 1e9, "WSOL with 80 ETH");

        // Second massive buy to push price even higher
        console.log("Executing second massive WSOL buy for maximum pump...");

        IV3SwapRouter.ExactInputSingleParams memory buyParams2 = IV3SwapRouter
            .ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: WSOL,
                fee: POOL_FEE,
                recipient: marketMaker,
                amountIn: 100 ether, // Even bigger purchase
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        uint256 wsolReceived2 = v3Router.exactInputSingle(buyParams2);
        console.log("Second buy: Market maker bought", wsolReceived2 / 1e9, "WSOL with 100 ETH");

        uint256 totalWSolBought = wsolReceived1 + wsolReceived2;
        console.log("Total WSOL bought:", totalWSolBought / 1e9, "WSOL with 180 ETH");
        console.log("WSOL price should now be SIGNIFICANTLY higher - targeting 10%+ profit!");

        vm.stopPrank();

        // Get current order to check expected profit
        Treasury.Order memory orderBeforeSell = treasury.getOrder(1);
        console.log("Order ETH spent (wei):", orderBeforeSell.ethSpent);
        console.log("Order ETH spent:", orderBeforeSell.ethSpent / 1e18, "ETH");
        console.log("Expected minimum ETH (with 10% profit):", (orderBeforeSell.ethSpent * 110 / 100) / 1e18, "ETH");
        console.log("Expected minimum ETH (wei):", orderBeforeSell.ethSpent * 110 / 100);

        // Try to sell - if market moved favorably, this should work
        vm.prank(user2);
        treasury.sell(1);

        uint256 finalBalance = address(treasury).balance;
        uint256 finalWsolBalance = IERC20(WSOL).balanceOf(address(treasury));
        uint256 finalMockTokenBalance = mockToken.balanceOf(address(treasury));

        console.log("Final treasury ETH balance:", finalBalance / 1e18, "ETH");
        console.log(
            "Final treasury WSOL balance:",
            finalWsolBalance / 1e9,
            "WSOL"
        );
        console.log(
            "Final treasury MockToken balance:",
            finalMockTokenBalance / 1e18,
            "MockToken"
        );

        // Verify buyback and burn occurred
        Treasury.Order memory order = treasury.getOrder(1);
        assertTrue(
            order.status == Treasury.OrderStatus.SUCCESS,
            "Order should be completed"
        );
        assertTrue(finalWsolBalance == 0, "All WSOL should be sold");

        console.log("SUCCESS: Buy and sell sequence completed successfully");
    }
}
