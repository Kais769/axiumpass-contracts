// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title AxiumPass SubscriptionVault4337
 * @notice Account-abstraction-ready evolution of the SubscriptionVault:
 *         pull-based recurring stablecoin payments where the vault NEVER
 *         holds funds — every charge is a direct subscriber → merchant
 *         `transferFrom`. 100% non-custodial by construction.
 *
 *  ─── WHAT ERC-4337 CHANGES (AND WHAT IT DOES NOT) ──────────────────────
 *  ERC-4337 smart accounts interact with this vault exactly like EOAs, and
 *  three additions make the whole lifecycle gasless for the customer while
 *  keeping custody untouched:
 *
 *  1. `subscribeWithAuthorization` — the customer SIGNS an EIP-712
 *     authorization off-chain ({merchant, token, amount, period, cap,
 *     nonce, deadline}); the keeper submits it and pays the gas. Signature
 *     verification uses SignatureChecker, so it accepts BOTH an EOA
 *     signature (ECDSA) and a smart-account signature (ERC-1271) — the
 *     ERC-4337 wallet compatibility path.
 *  2. `subscribeWithPermit` — piggybacks an EIP-2612 `permit` (USDC/EURC
 *     support it) so the token allowance itself is granted by signature:
 *     one signing session, zero customer transactions, zero customer gas.
 *  3. `cancelWithAuthorization` — revocation is ALSO a signature, so
 *     walking away never costs the customer more than joining did. A
 *     subscription the customer cannot cheaply revoke would not be
 *     non-custodial in spirit; this closes that gap.
 *
 *  The authorization is the "session key": authority scoped to exactly one
 *  (merchant, token, amount, period, payment-cap) tuple, consumed via a
 *  sequential per-subscriber nonce, expiring at `deadline`, revocable at
 *  any time. The keeper can only ever move `amount` per `period` to the
 *  fixed `recipient` — it can never redirect, upsize, or accelerate
 *  payments, and the contract holds no balance to steal.
 *
 *  ─── SECURITY HARDENING (v2.1) ─────────────────────────────────────────
 *  M-1  Token allowlist: only owner-approved stablecoins can be used, both
 *       at enrolment (`_create`) and at charge time (`processSubscription`).
 *       Enforces the "stablecoins only" invariant on-chain and shuts out
 *       callback/fee-on-transfer/rebasing tokens.
 *  M-2  Emergency pause (`Pausable`): the owner can freeze enrolments and
 *       charges if a flaw is found. Revocation (`cancelSubscription`,
 *       `cancelWithAuthorization`) is DELIBERATELY never pausable — a
 *       subscriber can always leave, even while paused.
 *  M-3  `nonReentrant` on `subscribeWithPermit` (it makes an external
 *       `permit` call) in addition to `processSubscription`.
 *  Ops  `Ownable2Step` (safe key rotation) + a `MIN_PERIOD` floor.
 *
 *  ─── SCHEDULING GUARANTEE ───────────────────────────────────────────────
 *  Unlike v1 (`nextPaymentTime += period`, which lets a lapsed subscription
 *  be charged repeatedly to "catch up"), v2 charges AT MOST ONCE per
 *  wall-clock period: if a charge lands late, the next window opens a full
 *  period after the charge, never earlier. Missed periods are simply lost
 *  revenue for the merchant — never a surprise multi-charge for the
 *  customer.
 *
 *  ⚠ AUDIT / EXTERNAL REVIEW REQUIRED before any mainnet deployment.
 *    Deploy to testnet behind a feature flag first; mainnet must be a
 *    guarded rollout (pause armed, allowlist minimal, low caps).
 */
contract SubscriptionVault4337 is EIP712, ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // ───── CONSTANTS ────────────────────────────────────────────────────
    /// @dev Lower bound on a subscription period. Blocks pathological
    ///      per-second configs; the backend enforces business periods too.
    uint256 public constant MIN_PERIOD = 1 hours;

    // ───── STORAGE ──────────────────────────────────────────────────────
    struct Subscription {
        address subscriber;
        address recipient;
        address token;
        uint256 amount;
        uint256 periodSeconds;
        uint256 nextPaymentTime;
        uint256 remainingPayments; // 0 = open-ended
        bool active;
    }

    /// @dev EIP-712 payload the customer signs to open a subscription.
    struct SubscriptionAuthorization {
        address subscriber;
        address recipient;
        address token;
        uint256 amount;
        uint256 periodSeconds;
        uint256 startTime; // 0 or past values are bumped to block.timestamp
        uint256 remainingPayments;
        uint256 nonce;
        uint256 deadline;
    }

    /// @dev EIP-712 payload the customer signs to revoke, gas-free.
    struct CancelAuthorization {
        uint256 subscriptionId;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 public constant SUBSCRIPTION_AUTHORIZATION_TYPEHASH = keccak256(
        "SubscriptionAuthorization(address subscriber,address recipient,address token,uint256 amount,uint256 periodSeconds,uint256 startTime,uint256 remainingPayments,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(uint256 subscriptionId,uint256 nonce,uint256 deadline)");

    uint256 public nextSubscriptionId;
    mapping(uint256 => Subscription) public subscriptions;
    /// @dev Sequential per-subscriber nonce shared by both authorization
    ///      types — every signature is single-use.
    mapping(address => uint256) public nonces;
    /// @dev M-1: only owner-approved tokens (stablecoins) may be used.
    mapping(address => bool) public allowedToken;

    address public keeper;

    // ───── EVENTS (v1-compatible shapes, backend listener reuse) ───────
    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);
    event TokenAllowed(address indexed token, bool allowed);
    event SubscriptionCreated(
        uint256 indexed id,
        address indexed subscriber,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 periodSeconds,
        uint256 nextPaymentTime,
        uint256 remainingPayments
    );
    event SubscriptionCanceled(uint256 indexed id, address indexed subscriber);
    event SubscriptionProcessed(
        uint256 indexed id,
        address indexed subscriber,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 timestamp
    );

    // ───── MODIFIERS ───────────────────────────────────────────────────
    modifier onlyKeeperOrSubscriber(uint256 id) {
        require(
            msg.sender == keeper || msg.sender == subscriptions[id].subscriber,
            "Vault: not authorized"
        );
        _;
    }

    constructor(address _keeper)
        EIP712("AxiumPass SubscriptionVault", "2")
        Ownable(msg.sender)
    {
        require(_keeper != address(0), "Vault: keeper required");
        keeper = _keeper;
        emit KeeperUpdated(address(0), _keeper);
    }

    // ───── ADMIN (owner-gated) ─────────────────────────────────────────
    function setKeeper(address newKeeper) external onlyOwner {
        require(newKeeper != address(0), "Vault: keeper required");
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @notice M-1: allow/deny a token (stablecoin) for use in the vault.
    function setTokenAllowed(address token, bool ok) external onlyOwner {
        require(token != address(0), "Vault: token required");
        allowedToken[token] = ok;
        emit TokenAllowed(token, ok);
    }

    /// @notice M-2: freeze enrolments and charges. Cancellation stays open.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice F18: renouncing ownership would permanently disable pause,
    ///         setKeeper, and the token allowlist — a one-way brick that also
    ///         bypasses the two-step transfer. Disabled: rotate the owner via
    ///         transferOwnership + acceptOwnership (Ownable2Step) instead.
    function renounceOwnership() public pure override {
        revert("Vault: renounce disabled");
    }

    // ───── DIRECT PATH (v1-compatible: EOA or smart account as sender) ─
    function createSubscription(
        address recipient,
        address token,
        uint256 amount,
        uint256 periodSeconds,
        uint256 startTime,
        uint256 remainingPayments
    ) external whenNotPaused returns (uint256 id) {
        require(startTime >= block.timestamp, "Vault: startTime in the past");
        id = _create(msg.sender, recipient, token, amount, periodSeconds, startTime, remainingPayments);
    }

    function cancelSubscription(uint256 id) external {
        Subscription storage sub = subscriptions[id];
        require(sub.active, "Vault: already inactive");
        require(msg.sender == sub.subscriber, "Vault: not subscriber");
        sub.active = false;
        emit SubscriptionCanceled(id, msg.sender);
    }

    // ───── SESSION PATH (signed authorizations, keeper pays the gas) ───
    function subscribeWithAuthorization(
        SubscriptionAuthorization calldata auth,
        bytes calldata signature
    ) public whenNotPaused returns (uint256 id) {
        require(block.timestamp <= auth.deadline, "Vault: authorization expired");
        require(auth.nonce == nonces[auth.subscriber], "Vault: bad nonce");
        nonces[auth.subscriber] += 1;

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SUBSCRIPTION_AUTHORIZATION_TYPEHASH,
                    auth.subscriber,
                    auth.recipient,
                    auth.token,
                    auth.amount,
                    auth.periodSeconds,
                    auth.startTime,
                    auth.remainingPayments,
                    auth.nonce,
                    auth.deadline
                )
            )
        );
        // ECDSA for EOAs, ERC-1271 for smart accounts (ERC-4337 wallets).
        require(
            SignatureChecker.isValidSignatureNow(auth.subscriber, digest, signature),
            "Vault: invalid signature"
        );

        // Signing happens strictly before inclusion — a start time that
        // drifted into the past simply starts now (deadline bounds staleness).
        uint256 startTime = auth.startTime > block.timestamp ? auth.startTime : block.timestamp;
        id = _create(
            auth.subscriber,
            auth.recipient,
            auth.token,
            auth.amount,
            auth.periodSeconds,
            startTime,
            auth.remainingPayments
        );
    }

    /// @notice Fully gasless enrolment for EIP-2612 tokens (USDC, EURC):
    ///         the allowance AND the subscription both come from signatures.
    /// @dev M-3: nonReentrant because `permit` is an external token call.
    function subscribeWithPermit(
        SubscriptionAuthorization calldata auth,
        bytes calldata signature,
        uint256 permitValue,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        // F27: reject a non-allowlisted token BEFORE calling permit() on it.
        // _create enforces the allowlist too, but checking first avoids an
        // attacker-influenced external call from a signature entrypoint.
        require(allowedToken[auth.token], "Vault: token not allowed");
        // Front-running a publicly visible permit makes a direct call
        // revert; tolerate that and verify the resulting allowance instead.
        try IERC20Permit(auth.token).permit(
            auth.subscriber, address(this), permitValue, permitDeadline, v, r, s
        ) {} catch {}
        require(
            IERC20(auth.token).allowance(auth.subscriber, address(this)) >= auth.amount,
            "Vault: permit did not grant allowance"
        );
        id = subscribeWithAuthorization(auth, signature);
    }

    /// @notice Gas-free revocation — leaving never costs more than joining.
    ///         Deliberately callable even while the vault is paused.
    function cancelWithAuthorization(
        CancelAuthorization calldata auth,
        bytes calldata signature
    ) external {
        Subscription storage sub = subscriptions[auth.subscriptionId];
        require(sub.active, "Vault: already inactive");
        require(block.timestamp <= auth.deadline, "Vault: authorization expired");
        require(auth.nonce == nonces[sub.subscriber], "Vault: bad nonce");
        nonces[sub.subscriber] += 1;

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CANCEL_AUTHORIZATION_TYPEHASH, auth.subscriptionId, auth.nonce, auth.deadline
                )
            )
        );
        require(
            SignatureChecker.isValidSignatureNow(sub.subscriber, digest, signature),
            "Vault: invalid signature"
        );
        sub.active = false;
        emit SubscriptionCanceled(auth.subscriptionId, sub.subscriber);
    }

    // ───── CHARGING ─────────────────────────────────────────────────────
    function processSubscription(uint256 id)
        external
        whenNotPaused
        nonReentrant
        onlyKeeperOrSubscriber(id)
    {
        Subscription storage sub = subscriptions[id];
        require(sub.active, "Vault: inactive");
        // M-1: a token can be de-allowed to halt its charges in an incident.
        require(allowedToken[sub.token], "Vault: token not allowed");
        require(block.timestamp >= sub.nextPaymentTime, "Vault: too early");

        IERC20 token = IERC20(sub.token);
        require(
            token.allowance(sub.subscriber, address(this)) >= sub.amount,
            "Vault: insufficient allowance"
        );
        require(token.balanceOf(sub.subscriber) >= sub.amount, "Vault: insufficient balance");

        // At most ONE charge per wall-clock period: a late charge opens the
        // next window a full period later; lapsed periods are never
        // back-charged (see contract-level doc).
        uint256 scheduled = sub.nextPaymentTime + sub.periodSeconds;
        sub.nextPaymentTime =
            scheduled > block.timestamp ? scheduled : block.timestamp + sub.periodSeconds;
        if (sub.remainingPayments > 0) {
            sub.remainingPayments -= 1;
            if (sub.remainingPayments == 0) {
                sub.active = false;
            }
        }

        // Direct subscriber → merchant transfer; the vault never holds funds.
        // `from` is not caller-supplied: it is the subscriber recorded at enrolment,
        // bound to msg.sender (createSubscription) or an EIP-712 / permit signer.
        // amount + recipient + period are fixed by the signed terms and cannot be
        // redirected — even by the keeper. This is the pull-payment mechanism, not
        // an arbitrary transfer; Slither's heuristic cannot see the enrolment binding.
        // slither-disable-next-line arbitrary-send-erc20
        token.safeTransferFrom(sub.subscriber, sub.recipient, sub.amount);

        emit SubscriptionProcessed(
            id, sub.subscriber, sub.recipient, sub.token, sub.amount, block.timestamp
        );
    }

    // ───── INTERNAL ─────────────────────────────────────────────────────
    function _create(
        address subscriber,
        address recipient,
        address token,
        uint256 amount,
        uint256 periodSeconds,
        uint256 startTime,
        uint256 remainingPayments
    ) internal returns (uint256 id) {
        require(subscriber != address(0), "Vault: subscriber required");
        require(recipient != address(0), "Vault: recipient required");
        require(token != address(0), "Vault: token required");
        require(allowedToken[token], "Vault: token not allowed"); // M-1
        require(amount > 0, "Vault: amount must be > 0");
        require(periodSeconds >= MIN_PERIOD, "Vault: period too short");

        id = nextSubscriptionId++;
        subscriptions[id] = Subscription({
            subscriber: subscriber,
            recipient: recipient,
            token: token,
            amount: amount,
            periodSeconds: periodSeconds,
            nextPaymentTime: startTime,
            remainingPayments: remainingPayments,
            active: true
        });

        emit SubscriptionCreated(
            id, subscriber, recipient, token, amount, periodSeconds, startTime, remainingPayments
        );
    }
}
