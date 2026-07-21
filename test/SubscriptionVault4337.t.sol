// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionVault4337} from "../src/SubscriptionVault4337.sol";
import {MockPermitToken, Mock1271Wallet} from "./mocks/Mocks4337.sol";

/// @notice Security + behaviour suite for the account-abstraction-ready
///         subscription vault. Focus areas: the non-custodial invariant
///         (vault balance is ALWAYS zero), signature safety (replay,
///         expiry, wrong signer, ERC-1271), gasless enrolment via
///         EIP-2612 permit, gas-free revocation, and the at-most-one
///         charge-per-period scheduling guarantee.
contract SubscriptionVault4337Test is Test {
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
            startTime: 0, // bumped to block.timestamp by the vault
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

    // ───── DIRECT PATH (v1 parity) ───────────────────────────────────────
    function test_DirectCreateAndProcess() public {
        vm.startPrank(subscriber);
        usdc.approve(address(vault), type(uint256).max);
        uint256 id = vault.createSubscription(
            merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, 0
        );
        vm.stopPrank();

        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), AMOUNT);
    }

    function test_Process_TooEarly_Reverts() public {
        uint256 id = _openDirect();
        vm.prank(keeper);
        vault.processSubscription(id);
        vm.prank(keeper);
        vm.expectRevert("Vault: too early");
        vault.processSubscription(id);
    }

    function test_Process_StrangerCannotTrigger() public {
        uint256 id = _openDirect();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Vault: not authorized");
        vault.processSubscription(id);
    }

    // ───── SIGNED ENROLMENT (session authorizations) ─────────────────────
    function test_SubscribeWithAuthorization_EOA() public {
        vm.prank(subscriber);
        usdc.approve(address(vault), type(uint256).max);

        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        bytes memory sig = _sign(subscriberPk, _authDigest(a));

        // Keeper submits and pays gas — the customer signed only.
        vm.prank(keeper);
        uint256 id = vault.subscribeWithAuthorization(a, sig);

        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), AMOUNT);
    }

    function test_SubscribeWithAuthorization_WrongSigner_Reverts() public {
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        bytes memory sig = _sign(0xBAD, _authDigest(a)); // attacker key
        vm.expectRevert("Vault: invalid signature");
        vault.subscribeWithAuthorization(a, sig);
    }

    function test_SubscribeWithAuthorization_Replay_Reverts() public {
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        bytes memory sig = _sign(subscriberPk, _authDigest(a));
        vault.subscribeWithAuthorization(a, sig);
        vm.expectRevert("Vault: bad nonce");
        vault.subscribeWithAuthorization(a, sig); // same signature again
    }

    function test_SubscribeWithAuthorization_Expired_Reverts() public {
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        a.deadline = block.timestamp - 1;
        bytes memory sig = _sign(subscriberPk, _authDigest(a));
        vm.expectRevert("Vault: authorization expired");
        vault.subscribeWithAuthorization(a, sig);
    }

    function test_SubscribeWithAuthorization_TamperedAmount_Reverts() public {
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        bytes memory sig = _sign(subscriberPk, _authDigest(a));
        a.amount = AMOUNT * 100; // keeper tries to upsize the charge
        vm.expectRevert("Vault: invalid signature");
        vault.subscribeWithAuthorization(a, sig);
    }

    // ───── FULLY GASLESS ENROLMENT (EIP-2612 permit) ─────────────────────
    function test_SubscribeWithPermit_FullyGasless() public {
        // The customer signs twice (permit + subscription) and never sends
        // a transaction; the keeper submits everything.
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        bytes memory sig = _sign(subscriberPk, _authDigest(a));
        (uint8 v, bytes32 r, bytes32 s) =
            _permitSig(subscriberPk, subscriber, type(uint256).max, a.deadline);

        vm.prank(keeper);
        uint256 id = vault.subscribeWithPermit(a, sig, type(uint256).max, a.deadline, v, r, s);

        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), AMOUNT);
    }

    function test_SubscribeWithPermit_ToleratesFrontRun() public {
        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(subscriber, 0);
        bytes memory sig = _sign(subscriberPk, _authDigest(a));
        (uint8 v, bytes32 r, bytes32 s) =
            _permitSig(subscriberPk, subscriber, type(uint256).max, a.deadline);

        // A griefer watches the mempool and consumes the permit first…
        usdc.permit(subscriber, address(vault), type(uint256).max, a.deadline, v, r, s);
        // …the enrolment still succeeds (allowance is in place).
        vm.prank(keeper);
        uint256 id = vault.subscribeWithPermit(a, sig, type(uint256).max, a.deadline, v, r, s);
        assertTrue(id == 0);
    }

    // ───── ERC-4337 SMART ACCOUNT (ERC-1271) ─────────────────────────────
    function test_SmartAccount_SubscribesViaERC1271() public {
        Mock1271Wallet wallet = new Mock1271Wallet(subscriber);
        usdc.mint(address(wallet), 100e6);
        vm.prank(subscriber);
        wallet.approveToken(usdc, address(vault), type(uint256).max);

        SubscriptionVault4337.SubscriptionAuthorization memory a = _auth(address(wallet), 0);
        // The wallet's owner key signs; the vault validates via ERC-1271.
        bytes memory sig = _sign(subscriberPk, _authDigest(a));

        vm.prank(keeper);
        uint256 id = vault.subscribeWithAuthorization(a, sig);

        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), AMOUNT);
    }

    // ───── REVOCATION ────────────────────────────────────────────────────
    function test_Cancel_BySubscriber_StopsCharges() public {
        uint256 id = _openDirect();
        vm.prank(subscriber);
        vault.cancelSubscription(id);
        vm.prank(keeper);
        vm.expectRevert("Vault: inactive");
        vault.processSubscription(id);
    }

    function test_CancelWithAuthorization_GasFree() public {
        uint256 id = _openDirect(); // direct create consumed no nonce
        uint256 nonce = vault.nonces(subscriber);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(subscriberPk, _cancelDigest(id, nonce, deadline));

        vm.prank(keeper); // relayer pays; customer only signed
        vault.cancelWithAuthorization(
            SubscriptionVault4337.CancelAuthorization({
                subscriptionId: id,
                nonce: nonce,
                deadline: deadline
            }),
            sig
        );
        vm.prank(keeper);
        vm.expectRevert("Vault: inactive");
        vault.processSubscription(id);
    }

    function test_CancelWithAuthorization_WrongSigner_Reverts() public {
        uint256 id = _openDirect();
        uint256 nonce = vault.nonces(subscriber);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(0xBAD, _cancelDigest(id, nonce, deadline));
        vm.expectRevert("Vault: invalid signature");
        vault.cancelWithAuthorization(
            SubscriptionVault4337.CancelAuthorization({
                subscriptionId: id,
                nonce: nonce,
                deadline: deadline
            }),
            sig
        );
    }

    // ───── SCHEDULING GUARANTEE ──────────────────────────────────────────
    function test_LapsedPeriods_NeverBackCharged() public {
        uint256 id = _openDirect();
        vm.prank(keeper);
        vault.processSubscription(id); // charge #1 at t0

        vm.warp(block.timestamp + 3 * PERIOD + 1 days); // wallet was empty for months
        vm.prank(keeper);
        vault.processSubscription(id); // exactly ONE recovery charge

        vm.prank(keeper);
        vm.expectRevert("Vault: too early"); // no catch-up double charge
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), 2 * AMOUNT);
    }

    function test_OnTimeCharges_KeepScheduleAnchor() public {
        uint256 id = _openDirect();
        vm.prank(keeper);
        vault.processSubscription(id);
        (,,,,, uint256 next,,) = vault.subscriptions(id);
        assertEq(next, block.timestamp + PERIOD); // anchored, no drift
    }

    function test_RemainingPayments_AutoDeactivates() public {
        vm.startPrank(subscriber);
        usdc.approve(address(vault), type(uint256).max);
        uint256 id = vault.createSubscription(
            merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, 2
        );
        vm.stopPrank();

        vm.prank(keeper);
        vault.processSubscription(id);
        vm.warp(block.timestamp + PERIOD);
        vm.prank(keeper);
        vault.processSubscription(id);

        (,,,,,,, bool active) = vault.subscriptions(id);
        assertFalse(active); // cap reached → self-deactivated
    }

    // ───── NON-CUSTODIAL INVARIANT ───────────────────────────────────────
    function test_VaultNeverHoldsFunds() public {
        uint256 id = _openDirect();
        vm.prank(keeper);
        vault.processSubscription(id);
        vm.warp(block.timestamp + PERIOD);
        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(address(vault)), 0); // custody impossible
    }

    function test_InsufficientBalance_Reverts() public {
        uint256 id = _openDirect();
        // Evaluate args BEFORE prank — an argument staticcall would consume it.
        address elsewhere = makeAddr("elsewhere");
        uint256 bal = usdc.balanceOf(subscriber);
        vm.prank(subscriber);
        usdc.transfer(elsewhere, bal);
        vm.prank(keeper);
        vm.expectRevert("Vault: insufficient balance");
        vault.processSubscription(id);
    }

    function test_SetKeeper_OnlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        vault.setKeeper(makeAddr("newKeeper"));
        vault.setKeeper(makeAddr("newKeeper")); // owner (this test) succeeds
    }

    function testFuzz_ProcessRespectsSignedTerms(uint96 amount, uint32 period) public {
        amount = uint96(bound(amount, 1, 500e6));
        period = uint32(bound(period, 1 hours, 365 days));

        vm.startPrank(subscriber);
        usdc.approve(address(vault), type(uint256).max);
        uint256 id = vault.createSubscription(
            merchant, address(usdc), amount, period, block.timestamp, 0
        );
        vm.stopPrank();

        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(merchant), amount); // never more than signed
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // ───── HELPERS ───────────────────────────────────────────────────────
    function _openDirect() internal returns (uint256 id) {
        vm.startPrank(subscriber);
        usdc.approve(address(vault), type(uint256).max);
        id = vault.createSubscription(
            merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, 0
        );
        vm.stopPrank();
    }
}
