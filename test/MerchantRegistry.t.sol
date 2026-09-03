// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MerchantRegistry} from "../src/MerchantRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MerchantRegistry — canonical Foundry suite
 * @notice The contract exists so the published volume number can be
 *         attributable without its PAST ever changing. The tests are written
 *         against the two ways the first design died under adversarial
 *         review: history that a re-registration could rewrite, and a role
 *         invariant that later writes could silently collapse. Each test
 *         names the contract line it kills if that line is removed.
 */
contract MerchantRegistryTest is Test {
    MerchantRegistry internal reg;

    address internal constant OWNER = address(0xA11CE);
    address internal constant REGISTRAR = address(0xB0B);
    address internal constant MERCHANT = address(0xCAFE);
    address internal constant STRANGER = address(0xDEAD);

    event MerchantRegistered(
        address indexed merchant, uint64 timestamp, uint256 spellIndex);
    event MerchantDeregistered(
        address indexed merchant, uint64 timestamp, uint256 spellIndex);

    function setUp() public {
        reg = new MerchantRegistry(OWNER, REGISTRAR);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Birth — kills: constructor's RolesMustDiffer / ZeroAddress reverts
    // ─────────────────────────────────────────────────────────────────────

    function test_constructor_refuses_one_key_holding_both_roles() public {
        vm.expectRevert(MerchantRegistry.RolesMustDiffer.selector);
        new MerchantRegistry(OWNER, OWNER);
    }

    function test_constructor_refuses_zero_registrar() public {
        vm.expectRevert(MerchantRegistry.ZeroAddress.selector);
        new MerchantRegistry(OWNER, address(0));
    }

    // ─────────────────────────────────────────────────────────────────────
    // THE REFUTATION TEST — the reason this file exists.
    // Kills: the append-only `spells.push(...)` in register(). The refused
    // 2026-08-14 design overwrote the single stored window on
    // re-registration, and this exact assertion flipped false: revenue
    // settled during spell 1 vanished from the record.
    // ─────────────────────────────────────────────────────────────────────

    function test_reregistration_never_rewrites_a_past_days_answer() public {
        vm.warp(1000);
        vm.prank(REGISTRAR);
        reg.register(MERCHANT);

        vm.warp(2000);
        vm.prank(REGISTRAR);
        reg.deregister(MERCHANT);

        vm.warp(3000);
        vm.prank(REGISTRAR);
        reg.register(MERCHANT); // the merchant comes back

        // Spell 1's window [1000, 2000) answers exactly as it did before the
        // merchant returned. THIS is the line the refused design broke.
        assertTrue(reg.wasRegisteredAt(MERCHANT, 1500),
            "revenue settled during spell 1 vanished from the record");
        assertTrue(reg.wasRegisteredAt(MERCHANT, 1000), "inclusive start");
        assertTrue(reg.wasRegisteredAt(MERCHANT, 1999), "last covered second");

        // The gap is a gap — counting it would be the opposite lie.
        assertFalse(reg.wasRegisteredAt(MERCHANT, 2000), "exclusive end");
        assertFalse(reg.wasRegisteredAt(MERCHANT, 2500), "gap stays a gap");

        // Spell 2 is live and open-ended.
        assertTrue(reg.wasRegisteredAt(MERCHANT, 3000));
        assertTrue(reg.wasRegisteredAt(MERCHANT, 999999));

        // Before any spell: nothing.
        assertFalse(reg.wasRegisteredAt(MERCHANT, 999));

        // The history itself is two spells, first one untouched.
        MerchantRegistry.Spell[] memory spells = reg.spellsOf(MERCHANT);
        assertEq(spells.length, 2);
        assertEq(spells[0].registeredAt, 1000);
        assertEq(spells[0].deregisteredAt, 2000);
        assertEq(spells[1].registeredAt, 3000);
        assertEq(spells[1].deregisteredAt, 0);

        assertEq(reg.registeredCount(), 1);
        assertEq(reg.totalSpells(), 2);
    }

    function test_same_second_churn_hands_the_boundary_to_the_new_spell()
        public
    {
        vm.warp(1000);
        vm.prank(REGISTRAR);
        reg.register(MERCHANT);

        vm.warp(5000);
        vm.startPrank(REGISTRAR);
        reg.deregister(MERCHANT);
        reg.register(MERCHANT); // same block.timestamp
        vm.stopPrank();

        // Half-open intervals: instant 5000 belongs to the NEW spell — never
        // counted twice, never lost. Kills: the `timestamp < s.deregisteredAt`
        // strict comparison in wasRegisteredAt().
        assertTrue(reg.wasRegisteredAt(MERCHANT, 5000));
        MerchantRegistry.Spell[] memory spells = reg.spellsOf(MERCHANT);
        assertEq(spells[0].deregisteredAt, 5000);
        assertEq(spells[1].registeredAt, 5000);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Registrar power — kills: onlyRegistrar, AlreadyRegistered,
    // NotCurrentlyRegistered, the ZeroAddress check in register()
    // ─────────────────────────────────────────────────────────────────────

    function test_only_the_registrar_registers_not_even_the_owner() public {
        vm.expectRevert(abi.encodeWithSelector(
            MerchantRegistry.NotRegistrar.selector, STRANGER));
        vm.prank(STRANGER);
        reg.register(MERCHANT);

        // The OWNER writing spells would collapse the two-role model from
        // the other side — the cold key must not be a hot key.
        vm.expectRevert(abi.encodeWithSelector(
            MerchantRegistry.NotRegistrar.selector, OWNER));
        vm.prank(OWNER);
        reg.register(MERCHANT);
    }

    function test_double_register_and_stray_deregister_revert() public {
        vm.startPrank(REGISTRAR);
        reg.register(MERCHANT);
        vm.expectRevert(abi.encodeWithSelector(
            MerchantRegistry.AlreadyRegistered.selector, MERCHANT));
        reg.register(MERCHANT);

        vm.expectRevert(abi.encodeWithSelector(
            MerchantRegistry.NotCurrentlyRegistered.selector, STRANGER));
        reg.deregister(STRANGER);
        vm.stopPrank();
    }

    function test_register_refuses_the_zero_address() public {
        vm.expectRevert(MerchantRegistry.ZeroAddress.selector);
        vm.prank(REGISTRAR);
        reg.register(address(0));
    }

    function test_events_carry_the_spell_index_an_indexer_replays() public {
        vm.warp(1000);
        vm.expectEmit(true, false, false, true);
        emit MerchantRegistered(MERCHANT, 1000, 0);
        vm.prank(REGISTRAR);
        reg.register(MERCHANT);

        vm.warp(2000);
        vm.expectEmit(true, false, false, true);
        emit MerchantDeregistered(MERCHANT, 2000, 0);
        vm.prank(REGISTRAR);
        reg.deregister(MERCHANT);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Role separation on EVERY writable path — the second refutation.
    // FoundersRegistry enforces owner != registrar only at birth; these
    // tests close each later path in turn.
    // ─────────────────────────────────────────────────────────────────────

    function test_setRegistrar_refuses_the_owner() public {
        // Kills: `newRegistrar == owner()` in setRegistrar().
        vm.expectRevert(MerchantRegistry.RolesMustDiffer.selector);
        vm.prank(OWNER);
        reg.setRegistrar(OWNER);
    }

    function test_the_two_step_collapse_is_caught_at_its_first_step() public {
        // The trap the adversarial review named: transfer ownership to A,
        // set registrar to A (A is not the CURRENT owner, so a naive check
        // passes), A accepts — one key, both roles. Kills:
        // `newRegistrar == pendingOwner()` in setRegistrar().
        address a = address(0xAAAA);
        vm.prank(OWNER);
        reg.transferOwnership(a);

        vm.expectRevert(MerchantRegistry.RolesMustDiffer.selector);
        vm.prank(OWNER);
        reg.setRegistrar(a);
    }

    function test_the_registrar_cannot_even_be_proposed_as_owner() public {
        // Kills: the registrar check in transferOwnership().
        vm.expectRevert(MerchantRegistry.RolesMustDiffer.selector);
        vm.prank(OWNER);
        reg.transferOwnership(REGISTRAR);
    }

    function test_the_registrar_cannot_accept_ownership() public {
        // Path 4 is unreachable through the public API (paths 2 and 3 close
        // it first) — belt to their braces. The override still refuses the
        // registrar BEFORE Ownable2Step's own pending-owner check, so even a
        // future code path that seeded pendingOwner wrongly would be caught.
        vm.expectRevert(MerchantRegistry.RolesMustDiffer.selector);
        vm.prank(REGISTRAR);
        reg.acceptOwnership();
    }

    function test_ownership_cannot_be_renounced() public {
        // Kills: the renounceOwnership override. An ownerless registry could
        // never rotate a compromised registrar out, while diagnose() kept
        // reporting healthy role separation over a corpse.
        vm.expectRevert(
            MerchantRegistry.OwnershipIsNotRenounceable.selector);
        vm.prank(OWNER);
        reg.renounceOwnership();
    }

    function test_rotation_to_a_clean_third_key_works() public {
        address fresh = address(0xF0E5);
        vm.prank(OWNER);
        reg.setRegistrar(fresh);
        assertEq(reg.registrar(), fresh);

        // The old registrar's power is gone the same second.
        vm.expectRevert(abi.encodeWithSelector(
            MerchantRegistry.NotRegistrar.selector, REGISTRAR));
        vm.prank(REGISTRAR);
        reg.register(MERCHANT);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Non-custodial + self-diagnosis
    // ─────────────────────────────────────────────────────────────────────

    function test_the_contract_refuses_value() public {
        // No receive, no fallback, no payable — a plain transfer reverts.
        vm.deal(STRANGER, 1 ether);
        vm.prank(STRANGER);
        (bool ok,) = address(reg).call{value: 1 wei}("");
        assertFalse(ok, "the registry accepted value: custody surface exists");
    }

    function test_diagnose_is_observed_not_remembered() public {
        (address owner_, address registrar_, address pending_,
         bool separated, bool renounceDisabled,
         uint256 count_, uint256 spells_) = reg.diagnose();
        assertEq(owner_, OWNER);
        assertEq(registrar_, REGISTRAR);
        assertEq(pending_, address(0));
        assertTrue(separated);
        assertTrue(renounceDisabled);
        assertEq(count_, 0);
        assertEq(spells_, 0);

        vm.prank(REGISTRAR);
        reg.register(MERCHANT);
        (,,,,, count_, spells_) = reg.diagnose();
        assertEq(count_, 1);
        assertEq(spells_, 1);
    }

    function test_spellsOfMany_returns_each_history_in_order() public {
        vm.warp(1000);
        vm.prank(REGISTRAR);
        reg.register(MERCHANT);

        address[] memory q = new address[](2);
        q[0] = MERCHANT;
        q[1] = STRANGER; // never registered
        MerchantRegistry.Spell[][] memory h = reg.spellsOfMany(q);
        assertEq(h.length, 2);
        assertEq(h[0].length, 1);
        assertEq(h[0][0].registeredAt, 1000);
        assertEq(h[1].length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Guards demanded by the adversarial audit (2026-08-15). Three mutations
    // EXECUTED against the 17-test suite survived it green: onlyRegistrar
    // stripped from deregister, onlyOwner stripped from setRegistrar, and
    // super.acceptOwnership() deleted. The contract was correct on every
    // path — the PROOF was not. These tests pin the unpinned siblings.
    // ─────────────────────────────────────────────────────────────────────

    function test_non_registrar_cannot_deregister_not_even_the_owner() public {
        // Kills: onlyRegistrar on deregister(). Without it, ANYONE closes any
        // merchant's open spell; append-only history makes the forced gap
        // permanently uncounted — falsification by omission, irreversible.
        vm.prank(REGISTRAR);
        reg.register(MERCHANT);

        vm.expectRevert(abi.encodeWithSelector(
            MerchantRegistry.NotRegistrar.selector, STRANGER));
        vm.prank(STRANGER);
        reg.deregister(MERCHANT);

        vm.expectRevert(abi.encodeWithSelector(
            MerchantRegistry.NotRegistrar.selector, OWNER));
        vm.prank(OWNER);
        reg.deregister(MERCHANT);
    }

    function test_non_owner_cannot_rotate_the_registrar() public {
        // Kills: onlyOwner on setRegistrar(). Without it, a COMPROMISED
        // registrar rotates itself a friend and the cold key loses the one
        // power the two-role model gives it.
        address fresh = address(0xF00D);
        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector, REGISTRAR));
        vm.prank(REGISTRAR);
        reg.setRegistrar(fresh);

        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        vm.prank(STRANGER);
        reg.setRegistrar(fresh);
    }

    function test_ownership_transfer_actually_completes() public {
        // Kills: deleting super.acceptOwnership() in the override — the
        // two-step would silently never finish, and with the old owner's key
        // lost, registrar rotation dies forever: the exact corpse that
        // disabling renounceOwnership exists to prevent.
        address a = address(0xA11A);
        vm.prank(OWNER);
        reg.transferOwnership(a);
        assertEq(reg.pendingOwner(), a);

        vm.prank(a);
        reg.acceptOwnership();
        assertEq(reg.owner(), a, "the two-step transfer never completed");
        assertEq(reg.pendingOwner(), address(0));

        // The OLD owner's power is gone the same second.
        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        vm.prank(OWNER);
        reg.setRegistrar(address(0xF00D));

        // And the NEW owner's power is real.
        vm.prank(a);
        reg.setRegistrar(address(0xF00D));
        assertEq(reg.registrar(), address(0xF00D));
    }

    function test_setRegistrar_refuses_the_zero_address() public {
        // Kills: the ZeroAddress check in setRegistrar() — the pending-owner
        // guard shadows it ONLY while pendingOwner() == 0, which is a
        // coincidence, not a guarantee.
        address a = address(0xA11A);
        vm.prank(OWNER);
        reg.transferOwnership(a); // pendingOwner != 0: the shadow is gone
        vm.expectRevert(MerchantRegistry.ZeroAddress.selector);
        vm.prank(OWNER);
        reg.setRegistrar(address(0));
    }

    function test_transfer_to_zero_cancels_a_pending_transfer() public {
        // OZ semantics preserved by the override: transferOwnership(0) is the
        // documented CANCEL of a pending two-step — and the registrar can
        // never be 0, so the zero check must not block it.
        address a = address(0xA11A);
        vm.startPrank(OWNER);
        reg.transferOwnership(a);
        reg.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(reg.pendingOwner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector, a));
        vm.prank(a);
        reg.acceptOwnership();
    }

    function test_same_second_register_then_deregister_is_an_empty_spell()
        public
    {
        // The audit's L-1, pinned as SEMANTICS rather than left as folklore:
        // a spell opened and closed within the same second is EMPTY under
        // half-open intervals — wasRegisteredAt(m, t) is false for its own
        // boundary second, and counters stay coherent. The adapter counts
        // strictly by wasRegisteredAt, so such a spell counts nothing: an
        // UNDERCOUNT (conservative), never an overcount. The backend driver
        // must simply never churn register/deregister in one batch.
        vm.warp(7000);
        vm.startPrank(REGISTRAR);
        reg.register(MERCHANT);
        reg.deregister(MERCHANT);
        vm.stopPrank();

        assertFalse(reg.isRegistered(MERCHANT));
        assertFalse(reg.wasRegisteredAt(MERCHANT, 7000),
            "an empty spell must count nothing: undercount, never overcount");
        MerchantRegistry.Spell[] memory spells = reg.spellsOf(MERCHANT);
        assertEq(spells.length, 1);
        assertEq(spells[0].registeredAt, 7000);
        assertEq(spells[0].deregisteredAt, 7000);
        assertEq(reg.registeredCount(), 0);
        assertEq(reg.totalSpells(), 1);

        // Re-registering later works and history keeps the empty spell.
        vm.warp(8000);
        vm.prank(REGISTRAR);
        reg.register(MERCHANT);
        assertTrue(reg.wasRegisteredAt(MERCHANT, 8000));
        assertEq(reg.spellsOf(MERCHANT).length, 2);
    }
}
