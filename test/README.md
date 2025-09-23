# Treasury Contract Tests

This directory contains comprehensive tests for the Treasury smart contract using **WSOL** as the target token and **MockERC20** as the buyback token.

## Test Configuration

- **Target Token**: WSOL (`0xD31a59c85aE9D8edEFeC411D448f90841571b89c`)
- **Buyback Token**: MockERC20 (deployed during test setup)
- **Amount per Order**: 1,000 WSOL (18 decimals)
- **Minimum PNL**: 5%
- **Pool Fee**: 0.3% (3000)
- **Caller Reward**: 0.001 ETH

## Test Setup Flow

1. **Deploy MockERC20**: Creates the buyback token with burn functionality
2. **Setup Liquidity**: Prepares WSOL/WETH and MockToken/WETH pools
3. **Deploy Treasury**: Configures Treasury with proper parameters
4. **Fund Treasury**: Provides 50 ETH for testing operations
5. **Execute Tests**: Runs buy/sell operations with different users

## Test Cases

### `testBuy()`
- Tests the public buy function with caller rewards
- Verifies WSOL token acquisition through Uniswap V3
- Checks order creation and status transitions
- Validates caller reward distribution

### `testSell()`
- Tests the public sell function with profit enforcement
- Verifies WSOL → ETH conversion
- Tests buyback and burn mechanism for MockERC20
- Validates minimum profit requirements (5%)

### `testBuyAndSellSequence()`
- Tests complete buy → sell workflow
- Verifies state transitions and balance changes
- Confirms buyback and burn execution
- Tests multi-user interaction (user1 buys, user2 sells)

### `testConfigAndIntegration()`
- Validates Treasury configuration parameters
- Tests getter functions and state queries
- Confirms proper contract integration
- Verifies address and parameter correctness

## Running Tests

### Quick Test Run
```bash
# Run all Treasury tests
forge test --match-contract TreasuryTest --fork-url $ETH_RPC_URL -vv

# Run specific test
forge test --match-test testBuy --fork-url $ETH_RPC_URL -vv
```

### Using Test Script
```bash
# Make script executable
chmod +x test_treasury.sh

# Run comprehensive test suite
./test_treasury.sh
```

## Environment Setup

Create a `.env` file with your RPC endpoint:
```bash
ETH_RPC_URL=https://eth-mainnet.alchemyapi.io/v2/YOUR_API_KEY
```

## Key Features Tested

1. **Token Operations**:
   - WSOL purchase through Uniswap V3
   - Exact output swaps with slippage protection
   - Token balance verification

2. **Profit Management**:
   - Minimum profit enforcement (5%)
   - Price calculation and validation
   - Target sell price computation

3. **Buyback & Burn**:
   - ETH → MockERC20 buyback swaps
   - Token burning through IBurnable interface
   - Event emission verification

4. **Access Control**:
   - Public function accessibility
   - Caller reward mechanisms
   - Owner-only emergency functions

5. **State Management**:
   - Order lifecycle tracking
   - Status transitions (BUYING → SELLING → SUCCESS)
   - Timestamp recording

## Notes

- Tests use Mainnet fork for realistic conditions
- WSOL pool existence is checked before operations
- MockERC20 provides controlled burn functionality
- Liquidity setup handles pool creation if needed
- Error handling for insufficient liquidity scenarios