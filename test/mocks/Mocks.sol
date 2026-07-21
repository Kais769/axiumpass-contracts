// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutoSwapRouter} from "../../src/AutoSwapRouter.sol";

/// @notice Minimal mintable ERC-20 with an optional reentrancy hook on transferFrom.
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Reentrancy attack hooks (off by default).
    address public hookTarget;
    bytes public hookData;
    bool public hookArmed;

    constructor(string memory _n, string memory _s, uint8 _d) {
        name = _n;
        symbol = _s;
        decimals = _d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
        emit Transfer(address(0), to, amt);
    }

    function armHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
        hookArmed = true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    function transfer(address to, uint256 amt) public returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        // Fire the reentrancy hook mid-transfer (simulates a malicious token).
        if (hookArmed) {
            hookArmed = false;
            (bool ok, ) = hookTarget.call(hookData);
            // Bubble nothing; we only care that the outer tx ultimately reverts.
            ok;
        }
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
        return true;
    }
}

/// @notice Mock 1inch aggregator. Pulls `fromToken` from caller, mints `out`
///         of `toToken` to `receiver` at a configurable rate (simulating price).
contract MockAggregator {
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;

    function setRate(uint256 n, uint256 d) external {
        rateNum = n;
        rateDen = d;
    }

    function swap(address fromToken, address toToken, uint256 amount, address receiver) external {
        IERC20(fromToken).transferFrom(msg.sender, address(this), amount);
        uint256 out = (amount * rateNum) / rateDen;
        MockERC20(toToken).mint(receiver, out);
    }
}

/// @notice Malicious aggregator that tries to reenter executeSwap during the swap.
contract ReentrantAggregator {
    AutoSwapRouter public router;
    uint256 public id;
    bytes public innerData;
    bool public armed;

    function configure(AutoSwapRouter _r, uint256 _id, bytes calldata _data) external {
        router = _r;
        id = _id;
        innerData = _data;
        armed = true;
    }

    // Matches MockAggregator.swap selector so the same swapData reaches here.
    function swap(address, address, uint256, address) external {
        if (armed) {
            armed = false;
            // Attempt reentry — must be blocked by nonReentrant (and/or onlyKeeper).
            router.executeSwap(id, 1, 0, innerData);
        }
    }
}
