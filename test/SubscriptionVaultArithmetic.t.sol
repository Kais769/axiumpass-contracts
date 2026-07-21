// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionVault} from "../src/SubscriptionVault.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice Arithmetic boundary / fuzz campaign for the LIVE v1 vault — the
///         "test boundary values" step of the arithmetic detect-and-neutralise
///         procedure (see `contracts/audit/VULN_CLASSES.md` §1.3, Step 4).
///
///         The property under test: the vault's checked (Solidity >=0.8)
///         arithmetic must **revert, never wrap** at the extremes, and its
///         `remainingPayments` decrement must never underflow at its `{0,1}`
///         boundary. These pin behaviour that is already correct so a future
///         change (e.g. adding an `unchecked` block) fails CI instead of
///         silently reintroducing an overflow primitive.
///
///         Mirrors the setup of `SubscriptionVault.t.sol`.
contract SubscriptionVaultArithmeticTest is Test {
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

    // ───── PERIOD ADD — overflow must revert, never wrap ───────────────────────

    /// @dev `type(uint256).max` period → `nextPaymentTime += periodSeconds`
    ///      overflows. Checked arithmetic must revert (Panic 0x11); it must NOT
    ///      wrap `nextPaymentTime` back to a tiny value (which would let the next
    ///      charge fire immediately). The revert is atomic: the transfer at
    ///      L177, which runs *before* the increment, is rolled back too.
    function test_PeriodOverflow_ChargeReverts_NoWrap() public {
        vm.prank(subscriber);
        uint256 id = vault.createSubscription(
            merchant, address(usdc), AMOUNT, type(uint256).max, block.timestamp, 0
        );
        vm.prank(keeper);
        vm.expectRevert(); // checked overflow on `nextPaymentTime += period`
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), 0, "no charge survives the overflow revert");
    }

    /// @dev The full boundary property over ALL period values: a charge either
    ///      succeeds (the add fits) or reverts (the add overflows) — there is no
    ///      third outcome where `nextPaymentTime` wraps.
    function testFuzz_ChargeAdvancesOrReverts_NeverWraps(uint256 period) public {
        period = bound(period, 1, type(uint256).max);
        uint256 start = block.timestamp;
        vm.prank(subscriber);
        uint256 id = vault.createSubscription(
            merchant, address(usdc), AMOUNT, period, start, 0
        );
        vm.prank(keeper);
        if (period > type(uint256).max - start) {
            vm.expectRevert();
            vault.processSubscription(id);
            assertEq(usdc.balanceOf(merchant), 0, "overflow => no charge");
        } else {
            vault.processSubscription(id);
            assertEq(usdc.balanceOf(merchant), AMOUNT, "in-range => exactly one charge");
        }
    }

    // ───── remainingPayments SUB — {0,1} boundary, no underflow ────────────────

    /// @dev A one-shot subscription (`remainingPayments == 1`) charges exactly
    ///      once, then the `> 0`-guarded decrement takes it to 0 and deactivates
    ///      it. A second charge is rejected as inactive — the counter never
    ///      underflows past its zero boundary.
    function test_RemainingPayments_DeactivatesAtBoundary() public {
        vm.prank(subscriber);
        uint256 id = vault.createSubscription(
            merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, 1
        );
        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), AMOUNT, "one-shot charged once");

        vm.warp(block.timestamp + PERIOD);
        vm.prank(keeper);
        vm.expectRevert("Vault: inactive");
        vault.processSubscription(id);
    }

    /// @dev Fuzz the fixed-count path: for any `n` in [1,12], exactly `n` charges
    ///      land and the `(n+1)`-th is rejected as inactive — the `> 0` guard
    ///      holds across the whole range, so `remainingPayments` never underflows.
    function testFuzz_RemainingPaymentsExhaustCleanly(uint8 n) public {
        uint256 count = bound(uint256(n), 1, 12);
        vm.prank(subscriber);
        uint256 id = vault.createSubscription(
            merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, count
        );
        for (uint256 i = 0; i < count; i++) {
            vm.prank(keeper);
            vault.processSubscription(id);
            vm.warp(block.timestamp + PERIOD);
        }
        assertEq(usdc.balanceOf(merchant), count * AMOUNT, "exactly `count` charges");

        vm.prank(keeper);
        vm.expectRevert("Vault: inactive");
        vault.processSubscription(id);
    }
}
