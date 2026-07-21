// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionVault} from "../src/SubscriptionVault.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice CI coverage for the LIVE v1 vault (audit F7 — it was previously
///         outside src/ and invisible to forge + Slither). Covers the charge
///         happy-path, guards, cancel/auth, and PINS the known F2 catch-up
///         behavior so it can never regress silently.
contract SubscriptionVaultV1Test is Test {
    SubscriptionVault internal vault;
    MockERC20 internal usdc;

    address internal keeper = makeAddr("keeper");
    address internal subscriber = makeAddr("subscriber");
    address internal merchant = makeAddr("merchant");

    uint256 internal constant AMOUNT = 10e6; // 10 USDC
    uint256 internal constant PERIOD = 30 days;

    function setUp() public {
        vault = new SubscriptionVault(keeper);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(subscriber, 1_000e6);
        vm.prank(subscriber);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _createSub() internal returns (uint256 id) {
        vm.prank(subscriber);
        id = vault.createSubscription(merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, 0);
    }

    // ───── HAPPY PATH ─────────────────────────────────────────────────────────
    function test_ProcessSubscription_MovesFundsDirectly() public {
        uint256 id = _createSub();
        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), AMOUNT, "merchant paid");
        // Non-custodial invariant: the vault never holds funds.
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds nothing");
    }

    // ───── GUARDS ─────────────────────────────────────────────────────────────
    function test_TooEarly_Reverts() public {
        vm.prank(subscriber);
        uint256 id = vault.createSubscription(
            merchant, address(usdc), AMOUNT, PERIOD, block.timestamp + 1 days, 0
        );
        vm.prank(keeper);
        vm.expectRevert("Vault: too early");
        vault.processSubscription(id);
    }

    function test_InsufficientAllowance_Reverts() public {
        uint256 id = _createSub();
        vm.prank(subscriber);
        usdc.approve(address(vault), AMOUNT - 1);
        vm.prank(keeper);
        vm.expectRevert("Vault: insufficient allowance");
        vault.processSubscription(id);
    }

    function test_InsufficientBalance_Reverts() public {
        uint256 id = _createSub();
        // Read the balance BEFORE prank: a nested call in the transfer's args
        // would otherwise consume the prank (transfer would run as this contract).
        uint256 bal = usdc.balanceOf(subscriber);
        vm.prank(subscriber);
        usdc.transfer(address(0xdead), bal); // drain
        vm.prank(keeper);
        vm.expectRevert("Vault: insufficient balance");
        vault.processSubscription(id);
    }

    // ───── CANCEL / AUTH ──────────────────────────────────────────────────────
    function test_Cancel_OnlySubscriber_StopsCharging() public {
        uint256 id = _createSub();

        vm.prank(merchant);
        vm.expectRevert("Vault: not subscriber");
        vault.cancelSubscription(id);

        vm.prank(subscriber);
        vault.cancelSubscription(id);

        vm.prank(keeper);
        vm.expectRevert("Vault: inactive");
        vault.processSubscription(id);
    }

    function test_Process_KeeperOrSubscriberOnly() public {
        uint256 id = _createSub();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Vault: not authorized");
        vault.processSubscription(id);

        // The subscriber may self-trigger their own charge.
        vm.prank(subscriber);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), AMOUNT);
    }

    // ───── PINNED KNOWN ISSUE (audit F2) ──────────────────────────────────────
    /// @dev v1 advances nextPaymentTime by a FIXED increment (not re-based to
    ///      now), so when K periods lapse, K charges are simultaneously eligible
    ///      in one block. v1 is immutable + live: the mitigation is keeper-side
    ///      (never issue catch-up calls) and v2 fixes it on-chain. This test pins
    ///      the behavior so any future change is a conscious one.
    function test_KnownIssue_F2_CatchUpBackCharges() public {
        uint256 id = _createSub();
        vm.warp(block.timestamp + 3 * PERIOD); // simulate 3 lapsed periods

        vm.startPrank(keeper);
        vault.processSubscription(id);
        vault.processSubscription(id);
        vault.processSubscription(id);
        vm.stopPrank();

        assertEq(usdc.balanceOf(merchant), 3 * AMOUNT, "v1 back-charges lapsed periods in one block");
    }
}
