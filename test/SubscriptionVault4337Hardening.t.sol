// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionVault4337} from "../src/SubscriptionVault4337.sol";
import {MockPermitToken} from "./mocks/Mocks4337.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice HARDENING / adversarial suite added on top of the reference
///         SubscriptionVault4337 tests. Each test maps to a gap flagged in
///         the internal audit:
///   (1) reentrancy via a malicious ERC-20 during a charge
///   (2) subscribeWithPermit with an invalid permit AND no pre-existing
///       allowance -> must revert "Vault: permit did not grant allowance"
///   (3) cancelWithAuthorization expiry + stale-nonce (replay) rejection
///   (4) cross-chain signature rejection (vm.chainId)
///   (5) shared nonce: subscribe-vs-cancel signed at the same nonce -> the
///       first submitted wins, the other is invalidated ("bad nonce")
///   (6) malicious ERC-1271 wallet (wrong magic value) -> rejected
///   (7) the "insufficient allowance" charge path
contract SubscriptionVault4337HardeningTest is Test {
    SubscriptionVault4337 internal vault;
    MockPermitToken internal usdc;

    address internal keeper = makeAddr("keeper");
    address internal merchant = makeAddr("merchant");

    uint256 internal subscriberPk = 0xA11CE;
    address internal subscriber;

    uint256 internal constant AMOUNT = 10e6; // 10 USDC
    uint256 internal constant PERIOD = 30 days;

    function setUp() public {
        subscriber = vm.addr(subscriberPk);
        vault = new SubscriptionVault4337(keeper);
        usdc = new MockPermitToken();
        usdc.mint(subscriber, 1_000e6);
        vault.setTokenAllowed(address(usdc), true); // M-1: allowlist the stablecoin
    }

    // ───── EIP-712 HELPERS (mirror the contract's domain exactly) ────────
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

    function _auth(address subj, uint256 nonce)
        internal
        view
        returns (SubscriptionVault4337.SubscriptionAuthorization memory)
    {
        return SubscriptionVault4337.SubscriptionAuthorization({
            subscriber: subj,
            recipient: merchant,
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

    function _cancelDigest(uint256 id, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(vault.CANCEL_AUTHORIZATION_TYPEHASH(), id, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _permitSig(uint256 pk, address owner_, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner_,
                address(vault),
                value,
                usdc.nonces(owner_),
                deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(pk, digest);
    }

    function _openDirect() internal returns (uint256 id) {
        vm.startPrank(subscriber);
        usdc.approve(address(vault), type(uint256).max);
        id = vault.createSubscription(merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, 0);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────
    // (1) REENTRANCY via a malicious ERC-20 that calls back during the charge
    // ─────────────────────────────────────────────────────────────────────
    function test_Reentrancy_MaliciousToken_Blocked() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(subscriber, 1_000e6);
        vault.setTokenAllowed(address(evil), true); // allow it, then test the guard behind it

        vm.startPrank(subscriber);
        evil.approve(address(vault), type(uint256).max);
        uint256 id =
            vault.createSubscription(merchant, address(evil), AMOUNT, PERIOD, block.timestamp, 0);
        vm.stopPrank();

        // Arm the token to re-enter processSubscription(id) during transferFrom.
        evil.arm(IReenterTarget(address(vault)), id);
        vm.prank(keeper);
        vm.expectRevert(); // ReentrancyGuardReentrantCall bubbles up
        vault.processSubscription(id);
        assertEq(evil.balanceOf(merchant), 0, "no charge slipped through");

        // Disarm: a normal charge still works and pays EXACTLY once.
        evil.disarm();
        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(evil.balanceOf(merchant), AMOUNT);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (2) subscribeWithPermit: invalid permit AND no pre-existing allowance
    // ─────────────────────────────────────────────────────────────────────
    function test_SubscribeWithPermit_InvalidPermit_NoAllowance_Reverts() public {
        // Subscriber has NOT approved the vault at all.
        assertEq(usdc.allowance(subscriber, address(vault)), 0);

        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        bytes memory sig = _sign(subscriberPk, _authDigest(a));

        // A permit signed by the WRONG key: permit() reverts (swallowed by the
        // contract's try/catch) and no allowance is granted.
        (uint8 v, bytes32 r, bytes32 s) =
            _permitSig(0xBAD, subscriber, type(uint256).max, a.deadline);

        vm.prank(keeper);
        vm.expectRevert("Vault: permit did not grant allowance");
        vault.subscribeWithPermit(a, sig, type(uint256).max, a.deadline, v, r, s);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (3) cancelWithAuthorization — expiry and stale-nonce (replay) rejection
    // ─────────────────────────────────────────────────────────────────────
    function test_CancelWithAuthorization_Expired_Reverts() public {
        uint256 id = _openDirect();
        uint256 nonce = vault.nonces(subscriber);
        uint256 deadline = block.timestamp - 1; // already expired
        bytes memory sig = _sign(subscriberPk, _cancelDigest(id, nonce, deadline));

        vm.prank(keeper);
        vm.expectRevert("Vault: authorization expired");
        vault.cancelWithAuthorization(
            SubscriptionVault4337.CancelAuthorization({
                subscriptionId: id,
                nonce: nonce,
                deadline: deadline
            }),
            sig
        );
    }

    function test_CancelWithAuthorization_StaleNonce_Reverts() public {
        // A signed SUBSCRIBE consumes nonce 0 -> nonce becomes 1.
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        vm.prank(keeper);
        uint256 subId = vault.subscribeWithAuthorization(a, _sign(subscriberPk, _authDigest(a)));

        // A cancel pre-signed at the now-stale nonce 0 must be rejected.
        uint256 staleNonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(subscriberPk, _cancelDigest(subId, staleNonce, deadline));

        vm.prank(keeper);
        vm.expectRevert("Vault: bad nonce");
        vault.cancelWithAuthorization(
            SubscriptionVault4337.CancelAuthorization({
                subscriptionId: subId,
                nonce: staleNonce,
                deadline: deadline
            }),
            sig
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // (4) CROSS-CHAIN rejection: a signature valid on chain A is invalid on B
    // ─────────────────────────────────────────────────────────────────────
    function test_CrossChain_SignatureRejected() public {
        // Sign for the current chain (the vault caches this chainId's domain).
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        bytes memory sig = _sign(subscriberPk, _authDigest(a));

        // Same address, different chain (e.g. Polygon->Optimism deterministic
        // CREATE). The domain separator now differs -> signature invalid.
        vm.chainId(999999);
        vm.prank(keeper);
        vm.expectRevert("Vault: invalid signature");
        vault.subscribeWithAuthorization(a, sig);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (5) SHARED NONCE: subscribe and cancel both signed at nonce N. The one
    //     submitted first wins; the other is invalidated.
    // ─────────────────────────────────────────────────────────────────────
    function test_SharedNonce_SubscribeWinsCancelInvalidated() public {
        // A pre-existing subscription opened via the DIRECT path (no nonce used).
        uint256 existingId = _openDirect();
        assertEq(vault.nonces(subscriber), 0);

        // Customer signs BOTH at nonce 0: a new subscribe AND a cancel of the
        // existing sub (e.g. an SDK that pre-signs a "leave" authorization).
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        bytes memory subSig = _sign(subscriberPk, _authDigest(a));

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory cancelSig = _sign(subscriberPk, _cancelDigest(existingId, 0, deadline));

        // Subscribe is submitted first -> consumes nonce 0.
        vm.prank(keeper);
        vault.subscribeWithAuthorization(a, subSig);
        assertEq(vault.nonces(subscriber), 1);

        // The co-nonce cancel is now dead.
        vm.prank(keeper);
        vm.expectRevert("Vault: bad nonce");
        vault.cancelWithAuthorization(
            SubscriptionVault4337.CancelAuthorization({
                subscriptionId: existingId,
                nonce: 0,
                deadline: deadline
            }),
            cancelSig
        );

        // And the existing subscription is therefore still chargeable.
        (,,,,,,, bool active) = vault.subscriptions(existingId);
        assertTrue(active, "existing sub not wrongly cancelled");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (6) MALICIOUS ERC-1271 wallet returning the wrong magic value -> reject
    // ─────────────────────────────────────────────────────────────────────
    function test_MaliciousERC1271_WrongMagic_Rejected() public {
        BadWallet bad = new BadWallet();
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(address(bad), 0);
        // Any signature — the wallet always answers with a non-magic value.
        bytes memory sig = _sign(subscriberPk, _authDigest(a));

        vm.prank(keeper);
        vm.expectRevert("Vault: invalid signature");
        vault.subscribeWithAuthorization(a, sig);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (7) INSUFFICIENT ALLOWANCE charge path
    // ─────────────────────────────────────────────────────────────────────
    function test_Process_InsufficientAllowance_Reverts() public {
        vm.startPrank(subscriber);
        usdc.approve(address(vault), AMOUNT - 1); // one wei short of a charge
        uint256 id =
            vault.createSubscription(merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, 0);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert("Vault: insufficient allowance");
        vault.processSubscription(id);
    }

    // ─────────────────────────────────────────────────────────────────────
    // M-1 · Token allowlist (enrolment gate + emergency kill-switch)
    // ─────────────────────────────────────────────────────────────────────
    function test_TokenNotAllowed_RevertsAtCreate() public {
        MockPermitToken other = new MockPermitToken(); // never allow-listed
        other.mint(subscriber, 1_000e6);
        vm.startPrank(subscriber);
        other.approve(address(vault), type(uint256).max);
        vm.expectRevert("Vault: token not allowed");
        vault.createSubscription(merchant, address(other), AMOUNT, PERIOD, block.timestamp, 0);
        vm.stopPrank();
    }

    function test_SetTokenAllowed_OnlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        vault.setTokenAllowed(address(usdc), false);
    }

    function test_DeAllowToken_HaltsCharges() public {
        uint256 id = _openDirect();
        vm.prank(keeper);
        vault.processSubscription(id); // first charge succeeds
        vault.setTokenAllowed(address(usdc), false); // owner emergency de-allow
        vm.warp(block.timestamp + PERIOD);
        vm.prank(keeper);
        vm.expectRevert("Vault: token not allowed");
        vault.processSubscription(id);
    }

    // ─────────────────────────────────────────────────────────────────────
    // M-2 · Emergency pause (never traps a subscriber)
    // ─────────────────────────────────────────────────────────────────────
    function test_Paused_BlocksEnrolAndCharge_ButNotCancel() public {
        uint256 id = _openDirect();
        vault.pause();

        vm.startPrank(subscriber);
        vm.expectRevert(); // Pausable: EnforcedPause
        vault.createSubscription(merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, 0);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(); // charging frozen
        vault.processSubscription(id);

        // Cancellation ALWAYS works, even while paused.
        vm.prank(subscriber);
        vault.cancelSubscription(id);
        (,,,,,,, bool active) = vault.subscriptions(id);
        assertFalse(active);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // OZ Ownable
        vault.pause();
    }

    function test_Unpause_RestoresCharging() public {
        uint256 id = _openDirect();
        vault.pause();
        vault.unpause();
        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), AMOUNT);
    }

    // ─────────────────────────────────────────────────────────────────────
    // MIN_PERIOD floor · Ownable2Step key rotation
    // ─────────────────────────────────────────────────────────────────────
    function test_MinPeriod_Enforced() public {
        vm.startPrank(subscriber);
        usdc.approve(address(vault), type(uint256).max);
        // Read MIN_PERIOD() BEFORE expectRevert: a nested external call inside the
        // reverting statement would otherwise become the "next call" the cheatcode
        // watches, and MIN_PERIOD() (a view) does not revert.
        uint256 tooShort = vault.MIN_PERIOD() - 1;
        vm.expectRevert("Vault: period too short");
        vault.createSubscription(merchant, address(usdc), AMOUNT, tooShort, block.timestamp, 0);
        vm.stopPrank();
    }

    function test_OwnershipTransfer_TwoStep() public {
        address newOwner = makeAddr("newOwner");
        vault.transferOwnership(newOwner); // owner (this test) proposes
        assertEq(vault.owner(), address(this), "owner unchanged until accepted");

        vm.prank(makeAddr("intruder")); // only the pending owner may accept
        vm.expectRevert();
        vault.acceptOwnership();

        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
    }

    // ───── F18: renounce disabled ─────────────────────────────────────────────
    function test_RenounceOwnership_Disabled() public {
        vm.expectRevert("Vault: renounce disabled");
        vault.renounceOwnership();
    }

    // ───── F27: permit path rejects a non-allowlisted token before any call ────
    function test_SubscribeWithPermit_TokenNotAllowed_RevertsEarly() public {
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        a.token = makeAddr("notAllowedToken"); // never allowlisted
        // The allowlist check is the first statement, before permit() is called,
        // so no signature/permit is needed to hit it.
        vm.expectRevert("Vault: token not allowed");
        vault.subscribeWithPermit(a, "", 0, a.deadline, 0, bytes32(0), bytes32(0));
    }
}

// ─────────────────────────── MALICIOUS MOCKS ───────────────────────────

interface IReenterTarget {
    function processSubscription(uint256 id) external;
}

/// @notice ERC-20 whose transferFrom re-enters the vault, to probe the
///         nonReentrant guard on the charge path.
contract ReentrantToken is ERC20 {
    IReenterTarget internal target;
    uint256 internal reenterId;
    bool internal armed;

    constructor() ERC20("Evil", "EVIL") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(IReenterTarget _target, uint256 _id) external {
        target = _target;
        reenterId = _id;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override
        returns (bool)
    {
        if (armed) {
            // Re-enter the guarded charge function mid-transfer.
            target.processSubscription(reenterId);
        }
        return super.transferFrom(from, to, value);
    }
}

/// @notice ERC-1271 wallet that always returns a WRONG magic value.
contract BadWallet is IERC1271 {
    function isValidSignature(bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0xdeadbeef; // never the ERC-1271 magic (0x1626ba7e)
    }
}
