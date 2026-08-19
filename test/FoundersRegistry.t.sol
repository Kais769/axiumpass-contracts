// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FoundersRegistry} from "../src/FoundersRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title FoundersRegistry — canonical Foundry suite
 * @notice This contract exists to stop a marketing sentence from being a lie
 *         ("your name engraved in the smart contract"). The tests are therefore
 *         written against that sentence: every way the record could still be
 *         changed, moved, erased, faked or lost is asserted impossible.
 */
contract FoundersRegistryTest is Test {
    FoundersRegistry internal reg;

    address internal owner = address(0xA11CE);
    address internal registrar = address(0xB0B);
    address internal stranger = address(0xBAD);

    uint8 internal constant OG = 1;
    uint8 internal constant GOLD = 2;

    event SeatEngraved(
        uint16 indexed position, address indexed holder, uint8 indexed edition, string name, uint64 engravedAt
    );
    event RegistrarChanged(address indexed previousRegistrar, address indexed newRegistrar);
    event RegistrySealed(uint16 totalEngraved, uint64 sealedAt);

    function setUp() public {
        reg = new FoundersRegistry(owner, registrar);
    }

    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    function _engrave(uint16 pos, address holder, uint8 edition, string memory name) internal {
        vm.prank(registrar);
        reg.engrave(pos, holder, edition, name);
    }

    // ── The programme, expressed as code ──────────────────────────────────
    function test_ConstantsMatchTheFoundersProgramme() public view {
        assertEq(reg.MAX_SEATS(), 100);
        assertEq(reg.OG_SEATS(), 10);
        assertEq(reg.EDITION_OG(), OG);
        assertEq(reg.EDITION_FOUNDER(), GOLD);
        assertEq(reg.MAX_NAME_BYTES(), 64);
        assertEq(reg.owner(), owner);
        assertEq(reg.registrar(), registrar);
        assertFalse(reg.sealed_());
    }

    function test_ConstructorRejectsZeroRegistrar() public {
        vm.expectRevert(FoundersRegistry.ZeroAddress.selector);
        new FoundersRegistry(owner, address(0));
    }

    // ── Engraving records what it should ──────────────────────────────────
    function test_EngraveStoresHolderEditionNameAndTime() public {
        vm.warp(1_800_000_000);
        _engrave(3, _holder(1), OG, "Nova SaaS");

        FoundersRegistry.Seat memory s = reg.seatAt(3);
        assertEq(s.holder, _holder(1));
        assertEq(s.edition, OG);
        assertEq(s.name, "Nova SaaS");
        assertEq(s.engravedAt, uint64(1_800_000_000));
        assertTrue(reg.isEngraved(3));
        assertEq(reg.seatOfHolder(_holder(1)), 3);
        assertEq(reg.totalEngraved(), 1);
    }

    function test_EngraveEmitsTheEvent() public {
        vm.warp(1_800_000_000);
        vm.expectEmit(true, true, true, true);
        emit SeatEngraved(11, _holder(2), GOLD, "Acme", uint64(1_800_000_000));
        _engrave(11, _holder(2), GOLD, "Acme");
    }

    function test_SeatOfReturnsTheHoldersSeat() public {
        _engrave(7, _holder(3), OG, "Seven");
        assertEq(reg.seatOf(_holder(3)).name, "Seven");
        // A wallet with no seat gets the zero struct, not a revert.
        assertEq(reg.seatOf(stranger).engravedAt, 0);
    }

    function test_SeatsInRangeReadsManySeatsAtOnce() public {
        _engrave(1, _holder(1), OG, "One");
        _engrave(2, _holder(2), OG, "Two");
        FoundersRegistry.Seat[] memory rows = reg.seatsInRange(1, 3);
        assertEq(rows.length, 3);
        assertEq(rows[0].name, "One");
        assertEq(rows[1].name, "Two");
        assertEq(rows[2].engravedAt, 0);
    }

    function test_SeatsInRangeRejectsBadBounds() public {
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.InvalidPosition.selector, uint16(0)));
        reg.seatsInRange(0, 5);
        // The revert names the position that is ACTUALLY wrong — reverting
        // with `from` for a bad `to` sends a caller debugging the wrong number.
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.InvalidPosition.selector, uint16(4)));
        reg.seatsInRange(5, 4);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.InvalidPosition.selector, uint16(101)));
        reg.seatsInRange(1, 101);
    }

    // ── "Engraved" means engraved ─────────────────────────────────────────
    function test_ASeatCanNeverBeRewritten() public {
        _engrave(5, _holder(1), OG, "First");
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.SeatAlreadyEngraved.selector, uint16(5)));
        reg.engrave(5, _holder(2), OG, "Second");
        assertEq(reg.seatAt(5).name, "First");
        assertEq(reg.totalEngraved(), 1);
    }

    function test_OneWalletCannotHoldTwoSeats() public {
        _engrave(4, _holder(1), OG, "Acme");
        vm.prank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(FoundersRegistry.HolderAlreadySeated.selector, _holder(1), uint16(4))
        );
        reg.engrave(20, _holder(1), GOLD, "Acme again");
    }

    // ── Edition coherence, enforced here and not trusted from the backend ─
    function test_GoldCannotBeImmortalisedAtAnOgPosition() public {
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.EditionMismatch.selector, uint16(3), GOLD));
        reg.engrave(3, _holder(1), GOLD, "Wrong edition");
    }

    function test_OgCannotBeImmortalisedAboveSeatTen() public {
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.EditionMismatch.selector, uint16(11), OG));
        reg.engrave(11, _holder(1), OG, "Wrong edition");
    }

    function testFuzz_EveryPositionAcceptsExactlyOneEdition(uint16 position, uint8 edition) public {
        position = uint16(bound(position, 1, 100));
        uint8 expected = position <= 10 ? OG : GOLD;
        vm.assume(edition != expected);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.EditionMismatch.selector, position, edition));
        reg.engrave(position, _holder(1), edition, "Nope");
    }

    function testFuzz_PositionsOutsideTheProgrammeAreRefused(uint16 position) public {
        vm.assume(position == 0 || position > 100);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.InvalidPosition.selector, position));
        reg.engrave(position, _holder(1), OG, "Nope");
    }

    function test_ZeroAddressCanNeverHoldASeat() public {
        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.ZeroAddress.selector);
        reg.engrave(1, address(0), OG, "Nobody");
    }

    // ── A permanent record deserves a validated name ──────────────────────
    function test_EmptyNameIsRefused() public {
        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.NameEmpty.selector);
        reg.engrave(1, _holder(1), OG, "");
    }

    function test_NameLongerThanTheMaximumIsRefused() public {
        string memory tooLong = new string(65);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.NameTooLong.selector, uint256(65)));
        reg.engrave(1, _holder(1), OG, tooLong);
    }

    function test_NameOfExactlyTheMaximumIsAccepted() public {
        bytes memory b = new bytes(64);
        for (uint256 i = 0; i < 64; ++i) {
            b[i] = "x";
        }
        _engrave(1, _holder(1), OG, string(b));
        assertEq(bytes(reg.seatAt(1).name).length, 64);
    }

    function test_ControlCharactersAreRefused() public {
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.NameHasControlCharacter.selector, uint256(4)));
        reg.engrave(1, _holder(1), OG, "Line\nBreak");
    }

    function test_NulByteIsRefused() public {
        bytes memory b = bytes("NulXByte");
        b[3] = 0x00;
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.NameHasControlCharacter.selector, uint256(3)));
        reg.engrave(1, _holder(1), OG, string(b));
    }

    function test_DelByteIsRefused() public {
        bytes memory b = bytes("DelXByte");
        b[3] = 0x7F;
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.NameHasControlCharacter.selector, uint256(3)));
        reg.engrave(1, _holder(1), OG, string(b));
    }

    function test_UntrimmedNamesAreRefused() public {
        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.NameNotTrimmed.selector);
        reg.engrave(1, _holder(1), OG, " Leading");

        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.NameNotTrimmed.selector);
        reg.engrave(1, _holder(1), OG, "Trailing ");
    }

    function test_Utf8NamesSurviveTheRoundTrip() public {
        _engrave(2, _holder(1), OG, unicode"Cafe Cree a Lyon");
        assertEq(reg.seatAt(2).name, unicode"Cafe Cree a Lyon");
    }

    // ── Access control ────────────────────────────────────────────────────
    function test_OnlyTheRegistrarCanEngrave() public {
        vm.prank(owner);
        vm.expectRevert(FoundersRegistry.NotRegistrar.selector);
        reg.engrave(1, _holder(1), OG, "Owner cannot");

        vm.prank(stranger);
        vm.expectRevert(FoundersRegistry.NotRegistrar.selector);
        reg.engrave(1, _holder(1), OG, "Stranger cannot");

        assertEq(reg.totalEngraved(), 0);
    }

    function test_OwnerCanRotateTheRegistrar() public {
        vm.expectEmit(true, true, false, false);
        emit RegistrarChanged(registrar, stranger);
        vm.prank(owner);
        reg.setRegistrar(stranger);

        assertEq(reg.registrar(), stranger);
        vm.prank(stranger);
        reg.engrave(1, _holder(1), OG, "After rotation");

        // The old key is powerless the moment it is rotated out.
        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.NotRegistrar.selector);
        reg.engrave(2, _holder(2), OG, "Old key");
    }

    function test_RegistrarCannotBeSetToZero() public {
        vm.prank(owner);
        vm.expectRevert(FoundersRegistry.ZeroAddress.selector);
        reg.setRegistrar(address(0));
    }

    function test_StrangerCannotGovern() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.setRegistrar(stranger);

        // Read BEFORE the prank: `reg.totalEngraved()` is itself an external
        // call, so evaluating it as an argument consumes the prank and the
        // seal would be sent by this test contract instead of `stranger`.
        uint16 engraved = reg.totalEngraved();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.seal(engraved);
    }

    function test_OwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        reg.transferOwnership(stranger);
        assertEq(reg.owner(), owner);
        assertEq(reg.pendingOwner(), stranger);

        vm.prank(stranger);
        reg.acceptOwnership();
        assertEq(reg.owner(), stranger);
    }

    // ── Sealing: the honest end state ─────────────────────────────────────
    function test_SealingStopsEveryWriteForever() public {
        _engrave(1, _holder(1), OG, "Before the seal");

        vm.expectEmit(false, false, false, true);
        emit RegistrySealed(1, uint64(block.timestamp));
        vm.prank(owner);
        reg.seal(1);
        assertTrue(reg.sealed_());

        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.RegistryIsSealed.selector);
        reg.engrave(2, _holder(2), OG, "After the seal");

        vm.prank(owner);
        vm.expectRevert(FoundersRegistry.RegistryIsSealed.selector);
        reg.setRegistrar(stranger);

        uint16 engravedNow = reg.totalEngraved();
        vm.prank(owner);
        vm.expectRevert(FoundersRegistry.RegistryIsSealed.selector);
        reg.seal(engravedNow);

        assertEq(reg.seatAt(1).name, "Before the seal");
    }

    function test_OwnershipCannotBeRenouncedBeforeSealing() public {
        // Renouncing an unsealed registry would freeze the registrar forever:
        // no key rotation, and no way to ever close the wall.
        vm.prank(owner);
        vm.expectRevert(FoundersRegistry.RegistryNotSealed.selector);
        reg.renounceOwnership();

        uint16 engravedBeforeSeal = reg.totalEngraved();
        vm.prank(owner);
        reg.seal(engravedBeforeSeal);
        vm.prank(owner);
        reg.renounceOwnership();
        assertEq(reg.owner(), address(0));
    }

    // ── Non-custodial by construction ─────────────────────────────────────
    function test_TheRegistryCannotReceiveValue() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(reg).call{value: 1 ether}("");
        assertFalse(ok, "registry accepted ETH");
        assertEq(address(reg).balance, 0);
    }

    function test_UnknownCalldataReverts() public {
        (bool ok,) = address(reg).call(abi.encodeWithSignature("definitelyNotAFunction()"));
        assertFalse(ok);
    }

    // ── The whole wall ────────────────────────────────────────────────────
    function test_TheFullHundredSeatWallEngravesCoherently() public {
        for (uint16 p = 1; p <= 100; ++p) {
            _engrave(p, _holder(p), p <= 10 ? OG : GOLD, "Founder");
        }
        assertEq(reg.totalEngraved(), 100);

        FoundersRegistry.Seat[] memory rows = reg.seatsInRange(1, 100);
        uint256 ogCount;
        uint256 goldCount;
        for (uint256 i = 0; i < rows.length; ++i) {
            if (rows[i].edition == OG) ogCount++;
            if (rows[i].edition == GOLD) goldCount++;
        }
        assertEq(ogCount, 10);
        assertEq(goldCount, 90);

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.InvalidPosition.selector, uint16(101)));
        reg.engrave(101, _holder(101), GOLD, "One too many");
    }

    // ── Hardening added after the adversarial audit (2026-07-28) ──────────
    function test_ConstructorRejectsOwnerEqualToRegistrar() public {
        // One key holding both roles means a single compromise can seal the
        // wall forever, and that same key is the only one that could have
        // rotated itself out.
        vm.expectRevert(FoundersRegistry.OwnerMustNotBeRegistrar.selector);
        new FoundersRegistry(owner, owner);
    }

    function test_SealRequiresStatingTheStateBeingSealed() public {
        _engrave(1, _holder(1), OG, "One");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.SealStateMismatch.selector, uint16(0), uint16(1)));
        reg.seal(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FoundersRegistry.SealStateMismatch.selector, uint16(99), uint16(1)));
        reg.seal(99);
        assertFalse(reg.sealed_());
        vm.prank(owner);
        reg.seal(1);
        assertTrue(reg.sealed_());
    }

    function test_ZeroWidthAndBidiCharactersAreRefused() public {
        // Written as escapes: these bytes are invisible in a diff and in a
        // review, which is exactly why a permanent public record refuses them.
        string[5] memory bad = [
            unicode"Nova\u200bSaaS", // zero-width space
            unicode"Nova\u200eSaaS", // LTR mark
            unicode"Nova\u202eSaaS", // RTL override — renders text backwards
            unicode"Nova\u2066SaaS", // bidi isolate
            unicode"Nova\ufeffSaaS" // BOM
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(registrar);
            vm.expectRevert();
            reg.engrave(1, _holder(1), OG, bad[i]);
        }
        assertFalse(reg.isEngraved(1));
    }

    function test_C1ControlCharactersAreRefused() public {
        vm.prank(registrar);
        vm.expectRevert();
        reg.engrave(1, _holder(1), OG, unicode"Nova\u0085SaaS");
        vm.prank(registrar);
        vm.expectRevert();
        reg.engrave(1, _holder(1), OG, unicode"Nova\u009fSaaS");
    }

    function test_MalformedUtf8CanNeverBeWritten() public {
        bytes[6] memory bad = [
            bytes(hex"4e6f7661c3"), // truncated 2-byte sequence
            bytes(hex"4e6f7661e282"), // truncated 3-byte sequence
            bytes(hex"4e6f766180"), // stray continuation byte
            bytes(hex"4e6f7661c0af"), // overlong encoding
            bytes(hex"4e6f7661eda080"), // UTF-16 surrogate half
            bytes(hex"4e6f7661f5808080") // above U+10FFFF
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(registrar);
            vm.expectRevert(); // NameHasInvalidUtf8 at some index
            reg.engrave(1, _holder(1), OG, string(bad[i]));
        }
        assertFalse(reg.isEngraved(1));
    }

    function test_InvisibleEdgeSpacesAreRefused() public {
        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.NameNotTrimmed.selector);
        reg.engrave(1, _holder(1), OG, unicode"\u00a0Nova"); // NBSP
        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.NameNotTrimmed.selector);
        reg.engrave(1, _holder(1), OG, unicode"Nova\u00a0");
        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.NameNotTrimmed.selector);
        reg.engrave(1, _holder(1), OG, unicode"\u3000Nova"); // ideographic
        vm.prank(registrar);
        vm.expectRevert(FoundersRegistry.NameNotTrimmed.selector);
        reg.engrave(1, _holder(1), OG, unicode"Nova\u3000");
    }

    function test_LegitimateInternationalNamesStillPass() public {
        // The hardening must not exclude real merchants.
        _engrave(1, _holder(1), OG, unicode"Caf\u00e9 Cr\u00e9\u00e9 \u00e0 Lyon");
        _engrave(2, _holder(2), OG, unicode"\u5317\u4eac\u79d1\u6280");
        _engrave(3, _holder(3), OG, unicode"\u0634\u0631\u0643\u0629");
        assertEq(reg.totalEngraved(), 3);
    }
}
