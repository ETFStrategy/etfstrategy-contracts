# ETF Strategy Smart Contracts

A Solidity-based automated trading system built on Uniswap V3/V4 that implements ETF-style trading strategies. The contract automatically buys target tokens, takes profits based on configurable thresholds, and performs buyback-and-burn operations to manage token supply.

## Key Components

- **Treasury Contract**: Core trading engine managing buy/sell orders with configurable profit thresholds and automated execution
- **TaxHook**: Uniswap V4 hook that collects 10% fees on swaps and converts them to ETH for the treasury
- **Multi-DEX Integration**: Supports both Uniswap V3 (trading) and V4 (hooks & buybacks) for optimal liquidity and features

## Features

 Automated token buying with exact output amounts
 Profit-taking with configurable minimum PnL thresholds
 Buyback-and-burn mechanism for deflationary tokenomics
 Caller rewards system for decentralized execution
 Emergency withdrawal functions for contract safety