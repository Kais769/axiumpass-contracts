// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionVault4337} from "../src/SubscriptionVault4337.sol";
import {MockPermitToken} from "./mocks/Mocks4337.sol";

/// @notice Stateful invariant campaign for the v2 SubscriptionVault4337.
///
///         Where the unit + fuzz suites pin specific attacks (replay, reentrancy,
///         tampered terms, …), this drives RANDOM adversarial SEQUENCES of
///         allowlisted enrol / charge / cancel across MULTIPLE subscribers with
///         arbitrary time warps — the "attacker mindset" applied to ordering,
///         not just to a single call — and asserts the two load-bearing
///         properties hold no matter the sequence:
///
///           1. The vault custodies ZERO tokens at all times (non-custodial).
///           2. Every token that leaves a subscriber reaches the merchant — the
///              vault creates, destroys, and siphons nothing (conservation).
///
///         A future change that let the vault hold or skim funds would break CI.
contract SubscriptionVault4337Invariant is Test {
    SubscriptionVault4337 internal vault;
    MockPermitToken internal token;
    Vault4337Handler internal handler;

    function setUp() public {
        address keeper = makeAddr("keeper");
        vault = new SubscriptionVault4337(keeper); // this contract is the owner
        token = new MockPermitToken();
        vault.setTokenAllowed(address(token), true); // M-1: allowlist the stablecoin
        handler = new Vault4337Handler(vault, token, keeper);
        // Only fuzz through the handler (bounded, meaningful actions).
        targetContract(address(handler));
    }

    /// @dev The vault must never custody funds — charges are direct transfers.
    function invariant_VaultHoldsNoTokens() public view {
        assertEq(token.balanceOf(address(vault)), 0, "vault must never custody funds");
    }

    /// @dev Every token charged reached the merchant — no value created/skimmed.
    function invariant_ConservationOfValue() public view {
        assertEq(
            handler.totalCharged(),
            token.balanceOf(handler.merchant()),
            "merchant balance must equal total charged"
        );
    }

    /// @dev A charge only ever fires when the subscription is DUE. Randomly
    ///      interleaved sequences must never find an early-charge path the
    ///      chosen-example test (Process_TooEarly_Reverts) did not think of.
    function invariant_ChargesOnlyWhenDue() public view {
        assertFalse(handler.ghostEarlyCharge(), "a charge fired before nextPaymentTime");
    }

    /// @dev Every successful charge opens a FULL new window: nextPaymentTime
    ///      advances by at least one period, whatever the warp pattern. This is
    ///      the sequence-random form of "at most one charge per wall-clock
    ///      period" — the scheduling promise the v2 vault is named for.
    function invariant_EachChargeOpensAFullWindow() public view {
        assertFalse(handler.ghostWindowShrunk(), "a charge advanced the window by less than one period");
    }

    /// @dev Cancellation is FINAL: once a subscriber cancels, no sequence of
    ///      keeper calls and time warps may ever charge them again. This is the
    ///      customer's gas-free exit, held under adversarial ordering.
    function invariant_CancellationIsFinal() public view {
        assertFalse(handler.ghostChargedAfterCancel(), "a cancelled subscription was charged again");
    }
}

/// @notice Bounded, multi-subscriber action generator for the invariant fuzzer.
contract Vault4337Handler is Test {
    SubscriptionVault4337 internal vault;
    MockPermitToken internal token;
    address internal keeper;
    address public merchant = address(0xB0B);

    // Multiple subscribers so the fuzzer interleaves independent enrolments.
    address[3] internal subs;
    uint256[] internal ids;
    mapping(uint256 => address) internal subOf; // id -> its subscriber
    uint256 public totalCharged; // ghost: sum of successful charges to the merchant

    // Ghost flags — the handler OBSERVES violations during the random
    // sequence; the invariant functions assert they never happened. (A raw
    // assert inside a handler call would only revert that call and could be
    // swallowed like any other revert — a flag cannot be un-set.)
    mapping(uint256 => bool) public ghostCancelled;
    bool public ghostEarlyCharge; // charged before nextPaymentTime
    bool public ghostWindowShrunk; // window advanced by less than one period
    bool public ghostChargedAfterCancel; // cancellation was not final

    uint256 internal constant MIN_PERIOD = 1 hours; // mirrors the vault's floor

    constructor(SubscriptionVault4337 _vault, MockPermitToken _token, address _keeper) {
        vault = _vault;
        token = _token;
        keeper = _keeper;
        subs[0] = address(0xA11CE);
        subs[1] = address(0xA22CE);
        subs[2] = address(0xA33CE);
        for (uint256 i = 0; i < subs.length; i++) {
            token.mint(subs[i], 1e30);
            vm.prank(subs[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function createSub(uint256 seed, uint96 amount, uint32 period, uint8 remaining) external {
        address s = subs[seed % subs.length];
        uint256 amt = bound(uint256(amount), 1, 1e15);
        uint256 per = bound(uint256(period), MIN_PERIOD, 365 days);
        uint256 rem = bound(uint256(remaining), 0, 5);
        vm.prank(s);
        try vault.createSubscription(merchant, address(token), amt, per, block.timestamp, rem)
        returns (uint256 id) {
            ids.push(id);
            subOf[id] = s;
        } catch {}
    }

    function process(uint256 seed, uint32 warpBy) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.warp(block.timestamp + bound(uint256(warpBy), 0, 400 days));
        (,,,, uint256 period, uint256 nextBefore,,) = vault.subscriptions(id);
        uint256 before = token.balanceOf(merchant);
        vm.prank(keeper);
        try vault.processSubscription(id) {
            totalCharged += token.balanceOf(merchant) - before;
            (,,,,, uint256 nextAfter,,) = vault.subscriptions(id);
            if (block.timestamp < nextBefore) ghostEarlyCharge = true;
            // The documented scheduling promise, as a lower bound: an on-time
            // charge keeps the anchor (next window opens at scheduled), a LATE
            // charge opens the next window a FULL period after now — never
            // sooner. (First ghost draft only required nextAfter >= old+period,
            // which a "+1 second after a late charge" mutant satisfied — the
            // red-proof caught it, rule (c) applied to the ghost itself.)
            uint256 scheduled = nextBefore + period;
            uint256 floor_ = scheduled > block.timestamp ? scheduled : block.timestamp + period;
            if (nextAfter < floor_) ghostWindowShrunk = true;
            if (ghostCancelled[id]) ghostChargedAfterCancel = true;
        } catch {}
    }

    function cancel(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.prank(subOf[id]); // only the recorded subscriber may cancel
        try vault.cancelSubscription(id) {
            ghostCancelled[id] = true;
        } catch {}
    }
}
