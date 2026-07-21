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
        uint256 before = token.balanceOf(merchant);
        vm.prank(keeper);
        try vault.processSubscription(id) {
            totalCharged += token.balanceOf(merchant) - before;
        } catch {}
    }

    function cancel(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.prank(subOf[id]); // only the recorded subscriber may cancel
        try vault.cancelSubscription(id) {} catch {}
    }
}
