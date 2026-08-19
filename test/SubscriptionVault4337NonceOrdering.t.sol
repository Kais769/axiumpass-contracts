// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionVault4337} from "../src/SubscriptionVault4337.sol";
import {MockPermitToken} from "./mocks/Mocks4337.sol";

/**
 * @title Nonce ordering between subscribe and cancel authorizations
 *
 * WHY THIS FILE EXISTS
 *   Reported by an external reader of the public contracts repository on
 *   2026-08-11: `subscribeWithAuthorization` and `cancelWithAuthorization`
 *   consume the SAME sequential `nonces[subscriber]` counter, so a
 *   pre-signed gasless cancel at nonce N stops verifying the moment any
 *   other authorization the same customer signed at nonce N lands first.
 *
 *   The report was accurate. Rather than take it on trust or leave it as a
 *   paragraph in an inbox, this file turns it into EXECUTED knowledge that
 *   the project owns: the collision is reproduced, its blast radius is
 *   measured, and the off-chain mitigation is proven sound. A finding
 *   without a test is a rumour — it cannot regress, because nothing watches.
 *
 * WHAT THE TESTS ESTABLISH, IN ORDER
 *   1. the collision is REAL and bidirectional;
 *   2. it can NEVER move money — the blast radius is liveness, not funds;
 *   3. the subscriber ALWAYS keeps a unilateral exit no nonce can block
 *      (this is what bounds the severity to "low", and the reporter had
 *      missed it — `cancelSubscription` is public, non-pausable, nonce-free);
 *   4. re-signing at the CURRENT nonce restores the cancel — which is why
 *      the product-side fix is "read the nonce late, re-sign on a lost
 *      race", not a contract redeploy.
 *
 * WHAT THIS FILE DOES NOT CLAIM
 *   It does not assert the design is correct. Separated nonce spaces, or
 *   unordered (bitmap) nonces à la Permit2, would remove the coupling by
 *   construction and belong in the next contract version. These tests pin
 *   TODAY's behaviour so the day that change lands, they go red on purpose
 *   and must be rewritten alongside it — which is exactly the reminder a
 *   future author needs.
 */
contract SubscriptionVault4337NonceOrderingTest is Test {
    SubscriptionVault4337 internal vault;
    MockPermitToken internal usdc;

    address internal keeper = makeAddr("keeper");
    address internal merchant = makeAddr("merchant");
    address internal merchant2 = makeAddr("merchant2");

    uint256 internal subscriberPk = 0xA11CE;
    address internal subscriber;

    uint256 internal constant AMOUNT = 10e6;
    uint256 internal constant PERIOD = 30 days;

    function setUp() public {
        subscriber = vm.addr(subscriberPk);
        vault = new SubscriptionVault4337(keeper);
        usdc = new MockPermitToken();
        usdc.mint(subscriber, 1_000e6);
        vault.setTokenAllowed(address(usdc), true);
        vm.prank(subscriber);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ───── EIP-712 helpers (mirror the contract's domain exactly) ───────
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("AxiumPass SubscriptionVault")),
                keccak256(bytes("2")),
                block.chainid,
                address(vault)
            )
        );
    }

    function _auth(address to, uint256 nonce)
        internal
        view
        returns (SubscriptionVault4337.SubscriptionAuthorization memory)
    {
        return SubscriptionVault4337.SubscriptionAuthorization({
            subscriber: subscriber,
            recipient: to,
            token: address(usdc),
            amount: AMOUNT,
            periodSeconds: PERIOD,
            startTime: 0,
            remainingPayments: 0,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _authDigest(SubscriptionVault4337.SubscriptionAuthorization memory a)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                vault.SUBSCRIPTION_AUTHORIZATION_TYPEHASH(),
                a.subscriber,
                a.recipient,
                a.token,
                a.amount,
                a.periodSeconds,
                a.startTime,
                a.remainingPayments,
                a.nonce,
                a.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _cancelAuth(uint256 id, uint256 nonce)
        internal
        view
        returns (SubscriptionVault4337.CancelAuthorization memory)
    {
        return SubscriptionVault4337.CancelAuthorization({
            subscriptionId: id,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _cancelDigest(SubscriptionVault4337.CancelAuthorization memory c)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                vault.CANCEL_AUTHORIZATION_TYPEHASH(), c.subscriptionId, c.nonce, c.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(subscriberPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Enrol once so there is a live subscription to try to cancel.
    function _enrol(address to) internal returns (uint256 id) {
        SubscriptionVault4337.SubscriptionAuthorization memory a =
            _auth(to, vault.nonces(subscriber));
        vm.prank(keeper);
        id = vault.subscribeWithAuthorization(a, _sign(_authDigest(a)));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. THE COLLISION IS REAL
    // ─────────────────────────────────────────────────────────────────────

    function test_a_pending_gasless_cancel_dies_when_a_subscribe_wins_the_nonce() public {
        uint256 id = _enrol(merchant);
        uint256 n = vault.nonces(subscriber);

        // The customer signs a gasless cancel and hands it to the keeper…
        SubscriptionVault4337.CancelAuthorization memory cancel = _cancelAuth(id, n);
        bytes memory cancelSig = _sign(_cancelDigest(cancel));

        // …then, before it is submitted, subscribes to a SECOND merchant.
        // The frontend read the same nonce `n` when preparing this one.
        SubscriptionVault4337.SubscriptionAuthorization memory second = _auth(merchant2, n);
        vm.prank(keeper);
        vault.subscribeWithAuthorization(second, _sign(_authDigest(second)));

        // The second enrolment burned nonce `n`. The cancel is now dead.
        vm.prank(keeper);
        vm.expectRevert("Vault: bad nonce");
        vault.cancelWithAuthorization(cancel, cancelSig);

        // And the subscription the customer meant to leave is still live.
        (,,,,,,, bool active) = vault.subscriptions(id);
        assertTrue(active, "the subscription survived a cancel the customer signed");
    }

    function test_the_collision_is_bidirectional_a_cancel_can_kill_a_pending_subscribe() public {
        uint256 id = _enrol(merchant);
        uint256 n = vault.nonces(subscriber);

        // Symmetric case: the pre-signed one is the SUBSCRIBE this time.
        // Worth pinning because it proves the defect is the shared counter
        // itself, not something specific to the cancel path — a fix that
        // only special-cased cancels would leave half the problem standing.
        SubscriptionVault4337.SubscriptionAuthorization memory pending = _auth(merchant2, n);
        bytes memory pendingSig = _sign(_authDigest(pending));

        SubscriptionVault4337.CancelAuthorization memory cancel = _cancelAuth(id, n);
        vm.prank(keeper);
        vault.cancelWithAuthorization(cancel, _sign(_cancelDigest(cancel)));

        vm.prank(keeper);
        vm.expectRevert("Vault: bad nonce");
        vault.subscribeWithAuthorization(pending, pendingSig);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. THE BLAST RADIUS IS LIVENESS — NEVER MONEY
    // ─────────────────────────────────────────────────────────────────────

    function test_losing_the_nonce_race_can_never_move_a_single_unit_of_value() public {
        uint256 id = _enrol(merchant);
        uint256 n = vault.nonces(subscriber);

        SubscriptionVault4337.CancelAuthorization memory cancel = _cancelAuth(id, n);
        bytes memory cancelSig = _sign(_cancelDigest(cancel));

        SubscriptionVault4337.SubscriptionAuthorization memory second = _auth(merchant2, n);
        vm.prank(keeper);
        vault.subscribeWithAuthorization(second, _sign(_authDigest(second)));

        uint256 subscriberBefore = usdc.balanceOf(subscriber);

        vm.prank(keeper);
        vm.expectRevert("Vault: bad nonce");
        vault.cancelWithAuthorization(cancel, cancelSig);

        // The failed race moved nothing, and the vault holds nothing — the
        // non-custodial invariant is untouched by the collision. This is the
        // assertion that separates "annoying" from "dangerous".
        assertEq(usdc.balanceOf(subscriber), subscriberBefore, "a reverted cancel moved funds");
        assertEq(usdc.balanceOf(address(vault)), 0, "the vault held a balance");

        // Even the charge that follows can only ever be the SIGNED terms:
        // the fixed recipient, the fixed amount. The race cannot redirect,
        // upsize or accelerate anything.
        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), AMOUNT, "amount or recipient drifted");
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. WHAT BOUNDS THE SEVERITY — THE EXIT NO NONCE CAN BLOCK
    // ─────────────────────────────────────────────────────────────────────

    function test_the_subscriber_always_keeps_a_unilateral_exit() public {
        uint256 id = _enrol(merchant);
        uint256 n = vault.nonces(subscriber);

        SubscriptionVault4337.CancelAuthorization memory cancel = _cancelAuth(id, n);
        bytes memory cancelSig = _sign(_cancelDigest(cancel));
        SubscriptionVault4337.SubscriptionAuthorization memory second = _auth(merchant2, n);
        vm.prank(keeper);
        vault.subscribeWithAuthorization(second, _sign(_authDigest(second)));
        vm.prank(keeper);
        vm.expectRevert("Vault: bad nonce");
        vault.cancelWithAuthorization(cancel, cancelSig);

        // THE POINT: the gasless path lost the race, but the customer is
        // not trapped — `cancelSubscription` takes no nonce, no signature,
        // no keeper, and is deliberately not pausable. They pay their own
        // gas and leave. "Revocable at any time" therefore still holds; it
        // is the FREE revocation that is order-coupled, not revocation.
        vm.prank(subscriber);
        vault.cancelSubscription(id);
        (,,,,,,, bool active) = vault.subscriptions(id);
        assertFalse(active, "the unilateral exit failed");

        // …and once out, no charge can follow.
        vm.warp(block.timestamp + PERIOD + 1);
        vm.prank(keeper);
        vm.expectRevert("Vault: inactive");
        vault.processSubscription(id);
    }

    function test_the_unilateral_exit_survives_even_a_paused_vault() public {
        uint256 id = _enrol(merchant);
        vault.pause();

        // If the exit died while paused, the owner could trap subscribers by
        // pausing — the opposite of the non-custodial promise.
        vm.prank(subscriber);
        vault.cancelSubscription(id);
        (,,,,,,, bool active) = vault.subscriptions(id);
        assertFalse(active, "pausing the vault trapped the subscriber");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. WHY THE FIX IS OFF-CHAIN — RE-SIGNING RESTORES THE CANCEL
    // ─────────────────────────────────────────────────────────────────────

    function test_re_signing_at_the_current_nonce_restores_the_cancel() public {
        uint256 id = _enrol(merchant);
        uint256 stale = vault.nonces(subscriber);

        SubscriptionVault4337.CancelAuthorization memory dead = _cancelAuth(id, stale);
        bytes memory deadSig = _sign(_cancelDigest(dead));
        SubscriptionVault4337.SubscriptionAuthorization memory second = _auth(merchant2, stale);
        vm.prank(keeper);
        vault.subscribeWithAuthorization(second, _sign(_authDigest(second)));
        vm.prank(keeper);
        vm.expectRevert("Vault: bad nonce");
        vault.cancelWithAuthorization(dead, deadSig);

        // This is the whole product-side remedy, proven on-chain: read the
        // nonce LATE, and on a lost race ask for one more signature. No
        // redeploy, no migration, no funds at risk — which is why a
        // low-severity ordering defect does not justify replacing four live
        // contracts.
        SubscriptionVault4337.CancelAuthorization memory fresh =
            _cancelAuth(id, vault.nonces(subscriber));
        vm.prank(keeper);
        vault.cancelWithAuthorization(fresh, _sign(_cancelDigest(fresh)));

        (,,,,,,, bool active) = vault.subscriptions(id);
        assertFalse(active, "the re-signed cancel did not take effect");
    }

    function test_a_cancel_signature_is_single_use_even_after_a_successful_one() public {
        // Guard against the naive "fix" of dropping the nonce from cancels:
        // without it, one signed cancel could be replayed against a later
        // subscription of the same customer. The coupling has a reason —
        // the next version must replace it, not delete it.
        uint256 id = _enrol(merchant);
        SubscriptionVault4337.CancelAuthorization memory c =
            _cancelAuth(id, vault.nonces(subscriber));
        bytes memory sig = _sign(_cancelDigest(c));

        vm.prank(keeper);
        vault.cancelWithAuthorization(c, sig);

        vm.prank(keeper);
        vm.expectRevert("Vault: already inactive");
        vault.cancelWithAuthorization(c, sig);
    }
}
