// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title AxiumPass Merchant Registry
 * @author AxiumPass
 * @notice The on-chain record of WHO counts as an AxiumPass merchant — so the
 *         published volume number can be attributable instead of farmable.
 *
 *  ── WHY THIS CONTRACT EXISTS (arbitration D-010) ─────────────────────────
 *  The public volume adapter sums `SubscriptionProcessed` events. A token
 *  allowlist restricts WHAT is counted, but nothing restricts WHO: anyone can
 *  subscribe to themselves in real, allowlisted USDC and be counted in full.
 *  No per-token filter can see that payer and payee are the same interest.
 *  This registry gives the adapter the missing predicate: count a charge only
 *  when its recipient was a registered merchant AT THAT MOMENT.
 *
 *  ── THE DESIGN THIS REPLACES, AND WHY IT WAS REFUSED ─────────────────────
 *  A first design (2026-08-14) stored ONE registration window per merchant.
 *  Adversarial review killed it: re-registering OVERWROTE the previous
 *  window, so a merchant who left and came back erased their own past —
 *  `wasRegisteredAt(m, t)` flipped from true to false for a `t` where real,
 *  settled revenue existed. A published time series whose past can change is
 *  not a record; a remedy that falsifies history is worse than the disease.
 *
 *  Here every registration opens a NEW spell and NOTHING can touch a closed
 *  one — there is no function that writes into past array entries, so the
 *  answer for any past instant is fixed at the moment the instant passes.
 *
 *  ── INTERVAL SEMANTICS, STATED EXACTLY ───────────────────────────────────
 *  A spell covers the half-open interval [registeredAt, deregisteredAt).
 *  `deregisteredAt == 0` means the spell is still open. Half-open, so that a
 *  deregister+register in the same second hands the boundary instant to the
 *  NEW spell and no instant is ever counted twice or lost.
 *
 *  ── TRUST MODEL, STATED PLAINLY ──────────────────────────────────────────
 *  The registrar decides who is a merchant. This does NOT make the number
 *  trustless — it makes it BOUNDED and ATTRIBUTABLE: a number AxiumPass
 *  vouches for with a key, instead of a number anyone can inflate for free.
 *  A reader may conclude "AxiumPass attests these recipients are merchants";
 *  a reader may NOT conclude "no listed merchant ever self-deals" — that
 *  claim would need KYB evidence, which lives off-chain.
 *
 *  ── ROLE SEPARATION ON EVERY PATH, NOT JUST AT BIRTH ─────────────────────
 *  `owner` (cold key) rotates the registrar; `registrar` (hot key) writes
 *  spells. One key holding both roles could rewrite the future of the record
 *  with no second key able to rotate it out. FoundersRegistry enforces the
 *  split only in its constructor; adversarial review of the first design
 *  showed two writable paths that silently collapse it later. Here EVERY
 *  path is closed:
 *    1. constructor            — reverts if owner == registrar;
 *    2. setRegistrar           — reverts if new registrar is the owner OR the
 *                                pending owner (the two-step trap: transfer
 *                                to A, set registrar A, A accepts — caught);
 *    3. transferOwnership      — reverts if the proposed owner is the
 *                                registrar;
 *    4. acceptOwnership        — reverts if the accepter is the registrar
 *                                (belt to 2's braces — whichever call comes
 *                                second is the one that reverts);
 *    5. renounceOwnership      — DISABLED. An ownerless registry cannot
 *                                rotate a compromised registrar, and
 *                                diagnose() would keep reporting
 *                                rolesSeparated=true over a corpse.
 *
 *  ── NON-CUSTODIAL BY CONSTRUCTION ────────────────────────────────────────
 *  No `receive`, no `fallback`, no `payable`, no token interface, no
 *  `delegatecall`, no `selfdestruct`. Same caveat as FoundersRegistry, so
 *  this contract does not tell the lie it exists to prevent: the EVM lets
 *  anyone FORCE value onto any address; anything sent here is stuck forever,
 *  because a rescue function would be a custody power. THIS ADDRESS IS NOT A
 *  PAYMENT ADDRESS.
 *
 *  ── WHAT THIS CONTRACT DOES NOT DO ───────────────────────────────────────
 *  It does not gate PAYMENTS. An unregistered merchant is paid on time, in
 *  full, by the vaults, which do not know this contract exists. Registration
 *  gates a NUMBER — presence in the published aggregate — never money.
 */
contract MerchantRegistry is Ownable2Step {
    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice One continuous period of registration. Closed spells are
    ///         immutable: no function in this contract writes to a past
    ///         array entry, which is what keeps history unfalsifiable.
    struct Spell {
        uint64 registeredAt;   // block timestamp, inclusive
        uint64 deregisteredAt; // block timestamp, exclusive; 0 = still open
    }

    /// @dev Full spell history per merchant, append-only, time-ordered by
    ///      construction (block timestamps are non-decreasing).
    ///
    ///      The slither suppression below is a MEASURED false positive, not a
    ///      silenced finding (PR #473, first CI run): `uninitialized-state`
    ///      fires because every write goes through a storage reference
    ///      (`Spell[] storage spells = _spells[m]; spells.push(...)`), a
    ///      pattern the detector does not follow. A storage mapping has no
    ///      initialization to miss — its every slot IS the zero value until
    ///      written — and the 17-test suite exercises the write path both
    ///      ways (append and close). Suppressing the whole detector in
    ///      slither.config.json would blind future contracts; one annotated
    ///      line blinds nothing.
    // slither-disable-next-line uninitialized-state
    mapping(address => Spell[]) private _spells;

    /// @notice The hot key allowed to open and close spells.
    address public registrar;

    /// @notice Merchants with an open spell right now.
    uint256 public registeredCount;

    /// @notice Spells ever opened, across all merchants. With
    ///         `registeredCount`, lets an indexer sanity-check a replay of
    ///         the event log against on-chain state.
    uint256 public totalSpells;

    // ─────────────────────────────────────────────────────────────────────
    // Errors — actionable sentences, never bare codes (guard 7 applies to
    // reverts too: the person reading this is debugging at 2am)
    // ─────────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error RolesMustDiffer();          // owner and registrar: one key, no
    error NotRegistrar(address who);  //   second key to rotate it out
    error AlreadyRegistered(address merchant);
    error NotCurrentlyRegistered(address merchant);
    error OwnershipIsNotRenounceable();

    // ─────────────────────────────────────────────────────────────────────
    // Events — `spellIndex` lets an indexer rebuild every window from the
    // log alone, and cross-check the rebuild against spellsOf()
    // ─────────────────────────────────────────────────────────────────────
    event MerchantRegistered(
        address indexed merchant, uint64 timestamp, uint256 spellIndex);
    event MerchantDeregistered(
        address indexed merchant, uint64 timestamp, uint256 spellIndex);
    event RegistrarChanged(
        address indexed previousRegistrar, address indexed newRegistrar);

    // ─────────────────────────────────────────────────────────────────────
    // Roles
    // ─────────────────────────────────────────────────────────────────────

    constructor(address initialOwner, address initialRegistrar)
        Ownable(initialOwner)
    {
        if (initialRegistrar == address(0)) revert ZeroAddress();
        if (initialRegistrar == initialOwner) revert RolesMustDiffer();
        registrar = initialRegistrar;
        emit RegistrarChanged(address(0), initialRegistrar);
    }

    modifier onlyRegistrar() {
        if (msg.sender != registrar) revert NotRegistrar(msg.sender);
        _;
    }

    /// @notice Rotate the hot key. Owner-only, and the new registrar may be
    ///         neither the owner nor the PENDING owner — the pending check
    ///         closes the two-step collapse (transfer to A, registrar A,
    ///         A accepts) at its first writable step.
    function setRegistrar(address newRegistrar) external onlyOwner {
        if (newRegistrar == address(0)) revert ZeroAddress();
        if (newRegistrar == owner() || newRegistrar == pendingOwner()) {
            revert RolesMustDiffer();
        }
        address previous = registrar;
        registrar = newRegistrar;
        emit RegistrarChanged(previous, newRegistrar);
    }

    /// @inheritdoc Ownable2Step
    /// @dev Path 3 of the role invariant: the registrar cannot even be
    ///      PROPOSED as owner.
    function transferOwnership(address newOwner)
        public
        override(Ownable2Step)
        onlyOwner
    {
        if (newOwner == registrar) revert RolesMustDiffer();
        super.transferOwnership(newOwner);
    }

    /// @inheritdoc Ownable2Step
    /// @dev Path 4: if the registrar somehow became pending owner anyway,
    ///      the acceptance is the last gate and it holds.
    function acceptOwnership() public override(Ownable2Step) {
        if (msg.sender == registrar) revert RolesMustDiffer();
        super.acceptOwnership();
    }

    /// @notice Disabled. An ownerless registry cannot rotate a compromised
    ///         registrar out, and its self-diagnosis would keep reporting
    ///         healthy role separation over a contract nobody governs.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipIsNotRenounceable();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Writes — the registrar's entire power, and nothing else
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Open a new spell for `merchant`, starting now.
    /// @dev Appends — never overwrites. The previous spell, if any, must be
    ///      closed; its record is beyond reach from this point on.
    function register(address merchant) external onlyRegistrar {
        if (merchant == address(0)) revert ZeroAddress();
        Spell[] storage spells = _spells[merchant];
        uint256 n = spells.length;
        if (n != 0 && spells[n - 1].deregisteredAt == 0) {
            revert AlreadyRegistered(merchant);
        }
        spells.push(Spell({
            registeredAt: uint64(block.timestamp),
            deregisteredAt: 0
        }));
        unchecked {
            registeredCount += 1;
            totalSpells += 1;
        }
        emit MerchantRegistered(merchant, uint64(block.timestamp), n);
    }

    /// @notice Close `merchant`'s open spell, effective now (exclusive).
    function deregister(address merchant) external onlyRegistrar {
        Spell[] storage spells = _spells[merchant];
        uint256 n = spells.length;
        if (n == 0 || spells[n - 1].deregisteredAt != 0) {
            revert NotCurrentlyRegistered(merchant);
        }
        spells[n - 1].deregisteredAt = uint64(block.timestamp);
        unchecked {
            registeredCount -= 1;
        }
        emit MerchantDeregistered(merchant, uint64(block.timestamp), n - 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views — what the adapter and anyone else may ask
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Is `merchant` registered right now?
    function isRegistered(address merchant) external view returns (bool) {
        Spell[] storage spells = _spells[merchant];
        uint256 n = spells.length;
        return n != 0 && spells[n - 1].deregisteredAt == 0;
    }

    /// @notice Was `merchant` registered at instant `timestamp`?
    /// @dev THE question the volume adapter asks, per event. Spells are
    ///      time-ordered, so the scan walks backwards and stops at the first
    ///      spell that started at or before `timestamp` — one comparison per
    ///      spell, and merchants rarely churn. The answer for a past instant
    ///      can never change: closed spells are unreachable to every write.
    function wasRegisteredAt(address merchant, uint64 timestamp)
        external
        view
        returns (bool)
    {
        Spell[] storage spells = _spells[merchant];
        for (uint256 i = spells.length; i > 0;) {
            unchecked { i -= 1; }
            Spell storage s = spells[i];
            if (s.registeredAt <= timestamp) {
                return s.deregisteredAt == 0 || timestamp < s.deregisteredAt;
            }
        }
        return false;
    }

    /// @notice Full spell history for `merchant` — lets an off-chain indexer
    ///         verify its event-log replay against state in one call.
    function spellsOf(address merchant)
        external
        view
        returns (Spell[] memory)
    {
        return _spells[merchant];
    }

    /// @notice Spell histories for a batch of merchants — the adapter's one
    ///         call per chain per day.
    function spellsOfMany(address[] calldata merchants)
        external
        view
        returns (Spell[][] memory histories)
    {
        histories = new Spell[][](merchants.length);
        for (uint256 i = 0; i < merchants.length; ++i) {
            histories[i] = _spells[merchants[i]];
        }
    }

    /// @notice Self-diagnosis — OBSERVED live, never remembered. Every field
    ///         is recomputed from state at call time, so a backend endpoint
    ///         can report this registry's real health without trusting a
    ///         cached flag.
    function diagnose()
        external
        view
        returns (
            address owner_,
            address registrar_,
            address pendingOwner_,
            bool rolesSeparated,
            bool renounceDisabled,
            uint256 registeredCount_,
            uint256 totalSpells_
        )
    {
        owner_ = owner();
        registrar_ = registrar;
        pendingOwner_ = pendingOwner();
        rolesSeparated = owner_ != address(0)
            && registrar_ != address(0)
            && owner_ != registrar_
            && pendingOwner_ != registrar_;
        renounceDisabled = true; // structural: the override always reverts
        registeredCount_ = registeredCount;
        totalSpells_ = totalSpells;
    }
}
