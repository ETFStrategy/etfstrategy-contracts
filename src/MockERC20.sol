// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "Mock Token") {
        _mint(msg.sender, 10_000_000 * 10 ** decimals());
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
