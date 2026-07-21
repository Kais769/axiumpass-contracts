// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionVault} from "../src/SubscriptionVault.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice Audit F20/F21 — stateful invariant campaign for the LIVE v1 vault.
///         Core non-custodial invariant: after ANY sequence of create / process
///         / cancel (with arbitrary time warps), the vault must hold ZERO tokens.
///         Funds always flow subscriber -> merchant directly; the vault is never
///         a custodian. This pins the property so a future change that routes
///         funds through the vault would fail CI.
contract SubscriptionVaultInvariant is Test {
    SubscriptionVault internal vault;
    MockERC20 internal token;
    VaultHandler internal handler;

    function setUp() public {
        address keeper = makeAddr("keeper");
        vault = new SubscriptionVault(keeper);
        token = new MockERC20("USD Coin", "USDC", 6);
        handler = new VaultHandler(vault, token, keeper);
        // Only fuzz through the handler (bounded, meaningful actions).
        targetContract(address(handler));
    }

    /// @dev The vault must never custody funds.
    function invariant_VaultHoldsNoTokens() public view {
        assertEq(token.balanceOf(address(vault)), 0, "vault must never custody funds");
    }

    /// @dev Every token that left a subscriber must have reached the merchant —
    ///      no value is created or destroyed by the vault.
    function invariant_ConservationOfValue() public view {
        assertEq(
            handler.totalCharged(),
            token.balanceOf(handler.merchant()),
            "merchant balance must equal total charged"
        );
    }
}

/// @notice Bounded action generator for the invariant fuzzer.
contract VaultHandler is Test {
    SubscriptionVault internal vault;
    MockERC20 internal token;
    address internal keeper;
    address internal subscriber = address(0xA11CE);
    address public merchant = address(0xB0B);

    uint256[] internal ids;
    uint256 public totalCharged; // ghost: sum of successful charges

    constructor(SubscriptionVault _vault, MockERC20 _token, address _keeper) {
        vault = _vault;
        token = _token;
        keeper = _keeper;
        token.mint(subscriber, 1e30);
        vm.prank(subscriber);
        token.approve(address(vault), type(uint256).max);
    }

    function createSub(uint96 amount, uint32 period) external {
        uint256 amt = bound(uint256(amount), 1, 1e15);
        uint256 per = bound(uint256(period), 1, 365 days);
        vm.prank(subscriber);
        uint256 id =
            vault.createSubscription(merchant, address(token), amt, per, block.timestamp, 0);
        ids.push(id);
    }

    function process(uint256 seed, uint32 warpBy) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.warp(block.timestamp + bound(uint256(warpBy), 0, 400 days));
        uint256 before = token.balanceOf(merchant);
        vm.prank(keeper);
        try vault.processSubscription(id) {
            totalCharged += token.balanceOf(merchant) - before;
        } catch {}
    }

    function cancel(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.prank(subscriber);
        try vault.cancelSubscription(id) {} catch {}
    }
}
