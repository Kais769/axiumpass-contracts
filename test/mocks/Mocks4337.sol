// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice 6-decimals EIP-2612 stablecoin stand-in (USDC/EURC both support permit).
contract MockPermitToken is ERC20, ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal ERC-4337-style smart account: ERC-1271 signature
///         validation against a single owner key + arbitrary execution
///         (enough to hold stablecoins and approve the vault).
contract Mock1271Wallet is IERC1271 {
    address public immutable signer;

    constructor(address _signer) {
        signer = _signer;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        override
        returns (bytes4)
    {
        (address recovered,,) = ECDSA.tryRecover(hash, signature);
        return recovered == signer ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    function approveToken(IERC20 token, address spender, uint256 amount) external {
        require(msg.sender == signer, "wallet: not owner");
        token.approve(spender, amount);
    }
}
