// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title AxiumPass Founders Registry
 * @author AxiumPass
 * @notice The permanent, public record of the 100 AxiumPass Founders seats.
 *
 *  ── WHY THIS CONTRACT EXISTS ─────────────────────────────────────────────
 *  The Founders programme promises "your name engraved in the smart contract".
 *  Until this contract, that sentence was a promise with nothing behind it.
 *  This is the thing that makes it TRUE: a seat, once engraved, can never be
 *  changed, moved, resold or erased — not by a founder, not by AxiumPass, not
 *  by the owner of this contract. Anyone can read it forever, from any node,
 *  without asking us.
 *
 *  ── NON-CUSTODIAL BY CONSTRUCTION, NOT BY PROMISE ────────────────────────
 *  This contract can never request, accept, move or spend value. There is no
 *  `receive()`, no `fallback()`, no `payable` function, no token interface, no
 *  `delegatecall` and no `selfdestruct`. It exposes no code path that touches
 *  an asset, so the AxiumPass non-custodial invariant is not merely respected
 *  here — it is unreachable to violate.
 *
 *  Stated precisely rather than absolutely, because this contract exists to
 *  stop a sentence from being a lie and must not tell one itself: the EVM lets
 *  anyone force ETH onto ANY address (another contract's `selfdestruct`, a
 *  block-reward payout), and anyone can mistakenly `transfer` an ERC-20 to any
 *  address. Value arriving that way would be permanently stuck, because there
 *  is deliberately no rescue function — adding one would trade a wording
 *  problem for a real custody power. THIS ADDRESS IS NOT A PAYMENT ADDRESS.
 *  Never send anything to it.
 *
 *  ── WHAT "ENGRAVED" MEANS, PRECISELY ─────────────────────────────────────
 *  A seat records the name AS IT WAS at the moment of engraving, together with
 *  the holder's wallet, the edition and the block timestamp. If the company
 *  later renames itself, the record does NOT follow: that is the point of an
 *  engraving, and the UI says so rather than implying a live mirror.
 *
 *  ── TRUST MODEL, STATED PLAINLY ──────────────────────────────────────────
 *  Seats are sold off-chain (card payment), so a `registrar` writes the
 *  record. This registry is therefore an ATTESTATION by AxiumPass that is
 *  permanent once made, not a trustless claim that anyone could mint. What the
 *  contract guarantees against is the thing that actually matters to a
 *  founder: that the record, once written, is beyond anyone's reach —
 *  including ours.
 *
 *  Be precise about what the registrar asserts: it asserts WHICH WALLET holds
 *  a seat, and this contract cannot check that claim. The wallet's consent is
 *  proved OFF-CHAIN — AxiumPass only engraves a wallet whose control was
 *  proved by a Sign-In-With-Ethereum signature (`owner_verified`), because
 *  otherwise anyone could buy a seat "for" a stranger's address and, thanks to
 *  the one-seat-per-wallet rule below, lock that stranger out of their own
 *  seat forever. That gate lives in `backend/founders_registry.py` and
 *  `backend/server.py`, and it is the reason `holder` may be trusted here.
 *
 *  `owner` and `registrar` are DIFFERENT keys, enforced in the constructor:
 *  the registrar is a low-value signer that can only write new seats, while
 *  the owner (cold / multisig) is the only key that can rotate it or seal.
 *  If one key held both, a single compromise could seal the wall permanently
 *  and nothing could rotate the attacker out — which is exactly the failure
 *  the two-role split exists to prevent.
 *
 *  Two further guarantees narrow the registrar's power to exactly "write a
 *  seat that has never been written":
 *   1. WRITE-ONCE — `engrave` reverts on an occupied position, and on a wallet
 *      that already holds a seat. There is no update, no delete, no transfer.
 *   2. EDITION COHERENCE — positions 1..OG_SEATS are OG (edition 1) and the
 *      rest are Founder (edition 2), enforced HERE. A backend bug cannot
 *      immortalise a Gold seat at position #003.
 *
 *  `seal()` is the endgame: the owner can permanently disable all future
 *  engraving. After sealing, this contract has no state-changing function that
 *  affects the record at all — the wall is finished, forever.
 */
contract FoundersRegistry is Ownable2Step {
    // ─────────────────────────────────────────────────────────────────────
    // Constants — the programme, expressed as code
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Total seats in the Founders programme (#001 … #100).
    uint16 public constant MAX_SEATS = 100;

    /// @notice Positions 1..OG_SEATS are the OG (Obsidian) edition.
    uint16 public constant OG_SEATS = 10;

    /// @notice Edition ids. 1 = OG · Obsidian, 2 = Founder · Gold.
    uint8 public constant EDITION_OG = 1;
    uint8 public constant EDITION_FOUNDER = 2;

    /// @notice Max engraved name length, in BYTES (not characters — a name in
    /// UTF-8 may use several bytes per character). Bounds the storage a single
    /// write can consume, so the cost of a seat is predictable and no name can
    /// grief the registry with an unbounded write.
    uint256 public constant MAX_NAME_BYTES = 64;

    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

    struct Seat {
        address holder; // the seat holder's wallet at engraving time
        uint64 engravedAt; // block timestamp; 0 == never engraved
        uint8 edition; // EDITION_OG | EDITION_FOUNDER
        string name; // the engraved name, immutable once written
    }

    /// @dev position (1..MAX_SEATS) => seat. Position 0 is never used, so a
    /// zero from `seatOfHolder` unambiguously means "no seat".
    mapping(uint16 => Seat) private _seats;

    /// @notice Reverse index: wallet => its seat position (0 = none).
    mapping(address => uint16) public seatOfHolder;

    /// @notice How many seats have been engraved so far.
    uint16 public totalEngraved;

    /// @notice The address allowed to engrave. Held by the AxiumPass keeper,
    /// and changeable by the owner so a keeper key rotation never bricks the
    /// registry (rotating keys is an operational safety practice, and it must
    /// not cost the programme its ability to record new seats).
    address public registrar;

    /// @notice Once true, no seat can ever be engraved again. Irreversible.
    bool public sealed_;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event SeatEngraved(
        uint16 indexed position, address indexed holder, uint8 indexed edition, string name, uint64 engravedAt
    );
    event RegistrarChanged(address indexed previousRegistrar, address indexed newRegistrar);
    event RegistrySealed(uint16 totalEngraved, uint64 sealedAt);

    // ─────────────────────────────────────────────────────────────────────
    // Errors — cheaper than strings, and each one names a single cause
    // ─────────────────────────────────────────────────────────────────────

    error NotRegistrar();
    error RegistryIsSealed();
    error RegistryNotSealed();
    error InvalidPosition(uint16 position);
    error SeatAlreadyEngraved(uint16 position);
    error HolderAlreadySeated(address holder, uint16 position);
    error ZeroAddress();
    error EditionMismatch(uint16 position, uint8 edition);
    error NameEmpty();
    error NameTooLong(uint256 length);
    error NameHasControlCharacter(uint256 index);
    error NameNotTrimmed();
    error NameHasInvalidUtf8(uint256 index);
    error NameHasHiddenCharacter(uint256 index);
    error OwnerMustNotBeRegistrar();
    error SealStateMismatch(uint16 expected, uint16 actual);

    // ─────────────────────────────────────────────────────────────────────
    // Construction
    // ─────────────────────────────────────────────────────────────────────

    /// @param initialOwner the address that governs the registrar and the seal
    /// @param initialRegistrar the address allowed to engrave (the keeper)
    constructor(address initialOwner, address initialRegistrar) Ownable(initialOwner) {
        if (initialRegistrar == address(0)) revert ZeroAddress();
        // The two roles MUST be different keys. If they were the same, one
        // compromise would let an attacker seal the wall permanently while the
        // holder of that key is also the only party who could have rotated
        // them out — the separation is the whole point, so it is enforced at
        // construction rather than left to a deploy script's good intentions.
        if (initialOwner == initialRegistrar) revert OwnerMustNotBeRegistrar();
        registrar = initialRegistrar;
        emit RegistrarChanged(address(0), initialRegistrar);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Engraving — the only way the record ever changes
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyRegistrar() {
        if (msg.sender != registrar) revert NotRegistrar();
        _;
    }

    /**
     * @notice Engrave one Founders seat, permanently.
     * @dev Reverts rather than overwriting in every ambiguous case. There is
     *      deliberately NO counterpart: no `updateSeat`, no `clearSeat`, no
     *      `transferSeat`. A mistake is therefore expensive by design — which
     *      is exactly what makes the record worth something.
     * @param position seat number, 1..MAX_SEATS
     * @param holder   the seat holder's wallet (non-zero, not already seated)
     * @param edition  EDITION_OG for 1..OG_SEATS, EDITION_FOUNDER above
     * @param name     the name to engrave (1..MAX_NAME_BYTES bytes)
     */
    function engrave(uint16 position, address holder, uint8 edition, string calldata name)
        external
        onlyRegistrar
    {
        if (sealed_) revert RegistryIsSealed();
        if (position == 0 || position > MAX_SEATS) revert InvalidPosition(position);
        if (holder == address(0)) revert ZeroAddress();
        if (_seats[position].engravedAt != 0) revert SeatAlreadyEngraved(position);

        uint16 existing = seatOfHolder[holder];
        if (existing != 0) revert HolderAlreadySeated(holder, existing);

        uint8 expected = position <= OG_SEATS ? EDITION_OG : EDITION_FOUNDER;
        if (edition != expected) revert EditionMismatch(position, edition);

        _validateName(name);

        uint64 ts = uint64(block.timestamp);
        _seats[position] = Seat({holder: holder, engravedAt: ts, edition: edition, name: name});
        seatOfHolder[holder] = position;
        unchecked {
            // Bounded by MAX_SEATS (100) via the write-once check above.
            totalEngraved += 1;
        }

        emit SeatEngraved(position, holder, edition, name, ts);
    }

    /**
     * @notice Rejects names that would be permanently ugly, unreadable or
     *         deceptive — the last gate before an irreversible write.
     * @dev Validated ON-CHAIN precisely because the write cannot be undone: a
     *      backend that one day forgets to sanitise must not be able to
     *      immortalise a newline, a NUL, an invisible character or a
     *      right-to-left override that makes the wall render a lie.
     *
     *      The check is deliberately thorough rather than cheap. Only 100
     *      names will ever be written, so a few thousand gas per seat is
     *      nothing next to a permanently broken record. It enforces:
     *        · 1..64 bytes
     *        · WELL-FORMED UTF-8 (RFC 3629 — no overlong forms, no surrogates,
     *          no truncated sequence). A malformed byte would render as "" on
     *          every explorer, forever.
     *        · no C0 controls or DEL, and no C1 controls (U+0080-U+009F)
     *        · no invisible / direction-flipping characters: zero-width
     *          (U+200B-U+200D), bidi marks and overrides (U+200E-U+200F,
     *          U+202A-U+202E, U+2066-U+2069), and BOM (U+FEFF)
     *        · trimmed of ASCII space, NBSP (U+00A0) and ideographic space
     *          (U+3000) at both ends
     */
    function _validateName(string calldata name) private pure {
        bytes memory b = bytes(name);
        uint256 len = b.length;
        if (len == 0) revert NameEmpty();
        if (len > MAX_NAME_BYTES) revert NameTooLong(len);

        uint256 i = 0;
        while (i < len) {
            uint8 c = uint8(b[i]);

            if (c < 0x80) {
                // ASCII: reject C0 controls and DEL.
                if (c < 0x20 || c == 0x7F) revert NameHasControlCharacter(i);
                // A space is only illegal at the very edges (see below).
                i += 1;
                continue;
            }

            // Multi-byte sequence: length, continuation bytes and range are
            // all checked, so a malformed name can never be written.
            uint256 seqLen;
            uint32 cp;
            if (c >= 0xC2 && c <= 0xDF) {
                seqLen = 2;
                cp = uint32(c & 0x1F);
            } else if (c >= 0xE0 && c <= 0xEF) {
                seqLen = 3;
                cp = uint32(c & 0x0F);
            } else if (c >= 0xF0 && c <= 0xF4) {
                seqLen = 4;
                cp = uint32(c & 0x07);
            } else {
                // 0x80-0xBF (stray continuation) or 0xC0/0xC1 (overlong).
                revert NameHasInvalidUtf8(i);
            }
            if (i + seqLen > len) revert NameHasInvalidUtf8(i);
            for (uint256 k = 1; k < seqLen; ++k) {
                uint8 cc = uint8(b[i + k]);
                if (cc < 0x80 || cc > 0xBF) revert NameHasInvalidUtf8(i + k);
                cp = (cp << 6) | uint32(cc & 0x3F);
            }
            // Overlong encodings, surrogates and out-of-range code points.
            if (seqLen == 3 && cp < 0x800) revert NameHasInvalidUtf8(i);
            if (seqLen == 4 && (cp < 0x10000 || cp > 0x10FFFF)) revert NameHasInvalidUtf8(i);
            if (cp >= 0xD800 && cp <= 0xDFFF) revert NameHasInvalidUtf8(i);

            // C1 controls — invisible, and just as corrupting as C0.
            if (cp >= 0x80 && cp <= 0x9F) revert NameHasControlCharacter(i);
            // Zero-width, bidi marks/overrides/isolates, and the BOM: these
            // are the characters that let a name LOOK like something it is
            // not, which on a permanent public wall is the worst outcome.
            if (
                (cp >= 0x200B && cp <= 0x200F) || (cp >= 0x202A && cp <= 0x202E)
                    || (cp >= 0x2066 && cp <= 0x2069) || cp == 0xFEFF
            ) revert NameHasHiddenCharacter(i);

            i += seqLen;
        }

        // Trimmed at both ends — a record with an invisible or leading space
        // renders differently from place to place and can never be corrected.
        if (_isEdgeSpace(b, 0)) revert NameNotTrimmed();
        if (_isEdgeSpace(b, len - 1)) revert NameNotTrimmed();
    }

    /// @dev True when the byte at `idx` is (or ends) a space-like character:
    ///      ASCII space, NBSP (C2 A0) or ideographic space (E3 80 80).
    function _isEdgeSpace(bytes memory b, uint256 idx) private pure returns (bool) {
        if (b[idx] == 0x20) return true;
        // Leading edge: look forward. Trailing edge: look back.
        if (idx == 0) {
            if (b.length >= 2 && b[0] == 0xC2 && b[1] == 0xA0) return true;
            if (b.length >= 3 && b[0] == 0xE3 && b[1] == 0x80 && b[2] == 0x80) return true;
            return false;
        }
        if (idx >= 1 && b[idx - 1] == 0xC2 && b[idx] == 0xA0) return true;
        if (idx >= 2 && b[idx - 2] == 0xE3 && b[idx - 1] == 0x80 && b[idx] == 0x80) return true;
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Governance — narrow on purpose
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Point the engraving right at a new keeper wallet.
    /// @dev Cannot touch any existing record; the only power this grants is
    ///      "write a seat that has never been written". Refused once sealed,
    ///      so a sealed registry is inert in every direction.
    function setRegistrar(address newRegistrar) external onlyOwner {
        if (sealed_) revert RegistryIsSealed();
        if (newRegistrar == address(0)) revert ZeroAddress();
        address previous = registrar;
        registrar = newRegistrar;
        emit RegistrarChanged(previous, newRegistrar);
    }

    /**
     * @notice Close the wall forever. Irreversible, by design and by absence:
     *         there is no `unseal`.
     * @param expectedTotalEngraved the number of seats the caller believes are
     *        engraved. It must match exactly.
     * @dev The most consequential action in this contract must not be the
     *      easiest one to fire. Ownership TRANSFER is two-step, yet sealing —
     *      which is permanent — used to be a single unconfirmable call: a
     *      stale dashboard, a fat finger or one compromised signature could
     *      end the programme early with no recourse. Requiring the caller to
     *      state the state they think they are sealing makes an accidental or
     *      stale seal revert instead of succeeding, at zero storage cost.
     */
    function seal(uint16 expectedTotalEngraved) external onlyOwner {
        if (sealed_) revert RegistryIsSealed();
        if (expectedTotalEngraved != totalEngraved) {
            revert SealStateMismatch(expectedTotalEngraved, totalEngraved);
        }
        sealed_ = true;
        emit RegistrySealed(totalEngraved, uint64(block.timestamp));
    }

    /**
     * @notice Give up ownership — allowed ONLY once the registry is sealed.
     * @dev OpenZeppelin's `Ownable` hands every contract a `renounceOwnership`,
     *      and here it would be a trap: renouncing on an UNSEALED registry
     *      freezes the registrar in place forever — nobody could ever rotate a
     *      compromised keeper key, and nobody could ever seal the wall. The
     *      programme has exactly one honest end state, and it is `seal()`.
     *      After sealing, ownership confers no power over the record at all,
     *      so letting it go is safe — and is a fitting last signal.
     */
    function renounceOwnership() public override onlyOwner {
        if (!sealed_) revert RegistryNotSealed();
        super.renounceOwnership();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The seat at `position`. An un-engraved seat returns the zero
    ///         struct — check `engravedAt != 0`, which is what `isEngraved` does.
    function seatAt(uint16 position) external view returns (Seat memory) {
        return _seats[position];
    }

    function isEngraved(uint16 position) external view returns (bool) {
        return _seats[position].engravedAt != 0;
    }

    /// @notice The seat held by `holder`, or the zero struct if none.
    function seatOf(address holder) external view returns (Seat memory) {
        return _seats[seatOfHolder[holder]];
    }

    /**
     * @notice Read a contiguous range of seats in one call — the whole wall is
     *         100 entries, so a front end or indexer never needs 100 requests.
     * @param from first position (>= 1)
     * @param to   last position, inclusive (<= MAX_SEATS)
     */
    function seatsInRange(uint16 from, uint16 to) external view returns (Seat[] memory out) {
        // Report the position that is ACTUALLY wrong: reverting with `from`
        // for an out-of-range `to` sends a caller debugging the wrong number.
        if (from == 0) revert InvalidPosition(from);
        if (to < from || to > MAX_SEATS) revert InvalidPosition(to);
        out = new Seat[](to - from + 1);
        for (uint16 p = from; p <= to; ++p) {
            out[p - from] = _seats[p];
        }
    }
}
