// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FailingERC20 is ERC20 {
    bool private s_failTransfer;
    bool private s_failTransferFrom;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function setFailTransfer(bool shouldFail) external {
        s_failTransfer = shouldFail;
    }

    function setFailTransferFrom(bool shouldFail) external {
        s_failTransferFrom = shouldFail;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (s_failTransfer) {
            return false;
        }
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (s_failTransferFrom) {
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}
