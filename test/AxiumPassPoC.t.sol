// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionVault} from "../src/SubscriptionVault.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @title AxiumPass — executable PoC / Benchmark harness (v1 LIVE vault)
/// @notice One adversarial Proof-of-Concept per TOP attack scenario. Each test
///         takes the ATTACKER's point of view, executes the exploit attempt, and
///         asserts the vault DEFENDS it — so the test passing == the invariant
///         holds. This doubles as the **Benchmark Engine corpus**: a stable,
///         severity-tagged set of "attacks we defend", regresss on every CI run,
///         and is the reproducible evidence an Immunefi Critical/High submission
///         requires (a PoC that demonstrates the boundary).
///
/// @dev Mapping (scenario ↔ registry ↔ severity) is in AxiumPassPoC.manifest.json,
///      which the Benchmark Engine ingests. Registry refs: assurance/INVARIANT_REGISTRY.md
///      (INV-*), memory/ATTACK_LEDGER.md findings. Severity = Immunefi v2.3 impact
///      IF the attack SUCCEEDED (it does not — that is the point).
///
/// The v1 vault is the highest-value target: it is LIVE, immutable, and custodies
/// real recurring stablecoin flow. Every PoC below is against it.
contract AxiumPassPoCHarness is Test {
    SubscriptionVault internal vault;
    MockERC20 internal usdc;

    address internal keeper = makeAddr("keeper");
    address internal subscriber = makeAddr("subscriber");
    address internal merchant = makeAddr("merchant");
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    uint256 internal constant AMOUNT = 10e6; // 10 USDC (6 decimals)
    uint256 internal constant PERIOD = 30 days;

    function setUp() public {
        vault = new SubscriptionVault(keeper);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(subscriber, 1_000e6);
        usdc.mint(attacker, 1_000e6);
        vm.prank(subscriber);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _enroll() internal returns (uint256 id) {
        // Due immediately: startTime == now, so the first period starts and the
        // sub is chargeable at block.timestamp (matches the on-chain semantics).
        vm.prank(subscriber);
        id = vault.createSubscription(merchant, address(usdc), AMOUNT, PERIOD, block.timestamp, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PoC-01 — Compromised keeper attempts to REDIRECT a charge to itself.
    // Severity-if-successful: CRITICAL (direct theft of merchant revenue).
    // Invariant defended: INV-KEEPER-NOREDIR + INV-RECIPIENT.
    // Attack: an attacker who has stolen the keeper key triggers billing hoping
    //         to steer funds to an address they control.
    // Defense proven: processSubscription(id) has NO recipient parameter; it can
    //         only pay sub.recipient (fixed at enrolment). The keeper is a trigger,
    //         not a treasurer. Funds land on the merchant; attacker gets zero.
    // ─────────────────────────────────────────────────────────────────────────
    function test_PoC01_KeeperCannotRedirectCharge() public {
        uint256 id = _enroll(); // due now

        uint256 attackerBefore = usdc.balanceOf(attacker);
        uint256 merchantBefore = usdc.balanceOf(merchant);

        // The attacker IS the keeper (key compromised) and fires the only lever
        // they have. There is no selector to set a recipient — the exploit does
        // not exist in the ABI. Best they can do is trigger the honest charge.
        vm.prank(keeper);
        vault.processSubscription(id);

        assertEq(usdc.balanceOf(attacker), attackerBefore, "attacker must gain nothing");
        assertEq(usdc.balanceOf(merchant), merchantBefore + AMOUNT, "funds go to the enrolled merchant only");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PoC-02 — Compromised keeper attempts to INFLATE the charged amount.
    // Severity-if-successful: CRITICAL (drain the subscriber's whole allowance).
    // Invariant defended: INV-AMOUNT.
    // Defense proven: processSubscription takes only `id`; the amount is
    //         sub.amount, fixed at enrolment. The subscriber's max-uint approval
    //         (a UX convenience) can NOT be exploited for more than one period's
    //         amount per period.
    // ─────────────────────────────────────────────────────────────────────────
    function test_PoC02_KeeperCannotInflateAmount() public {
        uint256 id = _enroll(); // due now

        uint256 subBefore = usdc.balanceOf(subscriber);
        vm.prank(keeper);
        vault.processSubscription(id);

        // Exactly one period's amount left the subscriber — not the full approval.
        assertEq(usdc.balanceOf(subscriber), subBefore - AMOUNT, "exactly the enrolled amount, no more");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PoC-03 — Double-charge WITHIN a single period (billing griefing / overcharge).
    // Severity-if-successful: HIGH (unauthorized extra charge; F2 catch-up abuse).
    // Invariant defended: INV-PERIOD + the F2 single-advance guarantee.
    // Defense proven: the second call in the same window reverts "too early", and
    //         after a legitimate charge nextPaymentTime advances by exactly ONE
    //         period (no unbounded catch-up that could bill many periods at once).
    // ─────────────────────────────────────────────────────────────────────────
    function test_PoC03_NoDoubleChargeWithinPeriod() public {
        uint256 id = _enroll(); // due now (nextPaymentTime == t0)

        vm.prank(keeper);
        vault.processSubscription(id); // legitimate charge #1 → nextPaymentTime = t0 + PERIOD

        // Immediate retry in the SAME period must be rejected (now == t0 < t0 + PERIOD).
        vm.prank(keeper);
        vm.expectRevert(bytes("Vault: too early"));
        vault.processSubscription(id);

        // Even after a LONG gap (3 periods elapsed) a single call advances by
        // exactly one period — it cannot bill three periods in one shot.
        vm.warp(block.timestamp + 3 * PERIOD);
        uint256 subBefore = usdc.balanceOf(subscriber);
        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(subscriber), subBefore - AMOUNT, "one call charges one period, never a catch-up burst");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PoC-04 — Vault CUSTODY drain (does the vault ever hold funds to steal?).
    // Severity-if-successful: CRITICAL (pooled-custody honeypot).
    // Invariant defended: INV-CUSTODY (non-custodial invariant, HARD GUARD 3).
    // Defense proven: funds move subscriber→merchant atomically via transferFrom;
    //         the vault's own token balance is ALWAYS zero, so there is nothing to
    //         drain and no withdraw()/sweep() selector exists.
    // ─────────────────────────────────────────────────────────────────────────
    function test_PoC04_VaultNeverHoldsCustody() public {
        uint256 id = _enroll();
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds nothing before");
        vm.warp(block.timestamp + PERIOD);
        vm.prank(keeper);
        vault.processSubscription(id);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds nothing after - no honeypot to drain");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PoC-05 — Arbitrary-`from` pull: attacker tries to bill a NON-consenting victim.
    // Severity-if-successful: CRITICAL (steal from anyone who ever approved the vault).
    // Invariant defended: INV-CUSTODY / consent — `from` is the subscriber recorded
    //         at enrolment (msg.sender in createSubscription), never caller-supplied.
    // Defense proven: the attacker can only ever create a subscription where THEY
    //         are the subscriber; a victim who has an approval to the vault (for
    //         their own legit sub) is never charged by the attacker's sub.
    // ─────────────────────────────────────────────────────────────────────────
    function test_PoC05_CannotBillNonConsentingVictim() public {
        // Victim has funds and even an approval to the vault (their own future sub).
        usdc.mint(victim, 500e6);
        vm.prank(victim);
        usdc.approve(address(vault), type(uint256).max);

        // Attacker enrolls, hoping the pull hits the victim. createSubscription
        // hard-codes sub.subscriber = msg.sender, so the attacker only ever bills
        // themselves.
        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        uint256 id = vault.createSubscription(attacker, address(usdc), AMOUNT, PERIOD, block.timestamp, 0);

        uint256 victimBefore = usdc.balanceOf(victim);
        vm.warp(block.timestamp + PERIOD);
        vm.prank(keeper);
        vault.processSubscription(id);

        assertEq(usdc.balanceOf(victim), victimBefore, "victim is never charged by someone else's subscription");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PoC-06 — Charge AFTER the subscriber revoked (cancel must be honored).
    // Severity-if-successful: HIGH (charging a cancelled subscription).
    // Invariant defended: subscriber sovereignty / SM-1 CANCELLED is terminal.
    // Defense proven: after cancelSubscription, processSubscription reverts
    //         "inactive" — the keeper cannot revive a revoked mandate.
    // ─────────────────────────────────────────────────────────────────────────
    function test_PoC06_NoChargeAfterCancel() public {
        uint256 id = _enroll();
        vm.prank(subscriber);
        vault.cancelSubscription(id);

        vm.warp(block.timestamp + PERIOD);
        vm.prank(keeper);
        vm.expectRevert(bytes("Vault: inactive"));
        vault.processSubscription(id);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PoC-07 — Back-dated first charge (on-chain analog of the C1 High backend fix).
    // Severity-if-successful: HIGH (force an immediate extra charge at enrolment
    //         by setting startTime in the past).
    // Invariant defended: INV-FIRSTCHARGE (startTime cannot precede now).
    // Defense proven: createSubscription reverts "startTime in the past", so no
    //         enrolment can be crafted to bill instantly for a period already gone.
    // ─────────────────────────────────────────────────────────────────────────
    function test_PoC07_CannotBackdateFirstCharge() public {
        vm.warp(1_000_000); // move off genesis so a "past" timestamp exists
        vm.prank(subscriber);
        vm.expectRevert(bytes("Vault: startTime in the past"));
        vault.createSubscription(merchant, address(usdc), AMOUNT, PERIOD, block.timestamp - 1, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PoC-08 — Unauthorized third party triggers billing (not keeper, not subscriber).
    // Severity-if-successful: MEDIUM (griefing — force charges on someone else's schedule).
    // Invariant defended: TB-KEEPER authorization boundary.
    // Defense proven: onlyKeeperOrSubscriber gates processSubscription; a random
    //         attacker call reverts "not authorized".
    // ─────────────────────────────────────────────────────────────────────────
    function test_PoC08_OutsiderCannotTriggerBilling() public {
        uint256 id = _enroll();
        vm.warp(block.timestamp + PERIOD);
        vm.prank(attacker);
        vm.expectRevert(bytes("Vault: not authorized"));
        vault.processSubscription(id);
    }
}
