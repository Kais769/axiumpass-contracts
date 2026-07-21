// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AxiumPass SubscriptionVault
 * @notice Vault contract enabling pull-based recurring stablecoin payments
 *         on Polygon and Base. Subscribers authorize this contract once,
 *         and a keeper (or anyone) triggers periodic transferFrom calls.
 *
 *  ─── HOW IT WORKS ──────────────────────────────────────────────────────
 *  1. User calls token.approve(vault, MAX) once (USDC/USDT EIP-20).
 *  2. User calls createSubscription(...) here to register their plan.
 *  3. Each period, the keeper calls processSubscription(id) which
 *     pulls `amount` from subscriber to recipient via transferFrom.
 *  4. User can call cancelSubscription(id) anytime to revoke.
 *
 *  ⚠  This implementation is a starting point — get an audit
 *     before holding meaningful TVL (CertiK, OpenZeppelin).
 *  ⚠  Use a re-entrancy guard / ERC20 SafeERC20 from OpenZeppelin
 *     in the production version (omitted here for clarity).
 */

interface IERC20 {
    function transferFrom(address from, address to, uint256 value)
        external
        returns (bool);
    function allowance(address owner, address spender)
        external
        view
        returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract SubscriptionVault {
    // ───── STORAGE ─────────────────────────────────────────────────────
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

    uint256 public nextSubscriptionId;
    mapping(uint256 => Subscription) public subscriptions;

    address public immutable owner;
    address public keeper; // address authorized to trigger processSubscription

    // ───── EVENTS ──────────────────────────────────────────────────────
    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);
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
    modifier onlyOwner() {
        require(msg.sender == owner, "Vault: not owner");
        _;
    }

    modifier onlyKeeperOrSubscriber(uint256 id) {
        require(
            msg.sender == keeper || msg.sender == subscriptions[id].subscriber,
            "Vault: not authorized"
        );
        _;
    }

    constructor(address _keeper) {
        owner = msg.sender;
        keeper = _keeper;
        emit KeeperUpdated(address(0), _keeper);
    }

    // ───── ADMIN ───────────────────────────────────────────────────────
    function setKeeper(address newKeeper) external onlyOwner {
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    // ───── CORE ────────────────────────────────────────────────────────
    function createSubscription(
        address recipient,
        address token,
        uint256 amount,
        uint256 periodSeconds,
        uint256 startTime,
        uint256 remainingPayments
    ) external returns (uint256 id) {
        require(recipient != address(0), "Vault: recipient required");
        require(token != address(0), "Vault: token required");
        require(amount > 0, "Vault: amount must be > 0");
        require(periodSeconds > 0, "Vault: period must be > 0");
        require(
            startTime >= block.timestamp,
            "Vault: startTime in the past"
        );

        id = nextSubscriptionId++;
        Subscription storage sub = subscriptions[id];
        sub.subscriber = msg.sender;
        sub.recipient = recipient;
        sub.token = token;
        sub.amount = amount;
        sub.periodSeconds = periodSeconds;
        sub.nextPaymentTime = startTime;
        sub.remainingPayments = remainingPayments;
        sub.active = true;

        emit SubscriptionCreated(
            id,
            msg.sender,
            recipient,
            token,
            amount,
            periodSeconds,
            startTime,
            remainingPayments
        );
    }

    function cancelSubscription(uint256 id) external {
        Subscription storage sub = subscriptions[id];
        require(sub.active, "Vault: already inactive");
        require(msg.sender == sub.subscriber, "Vault: not subscriber");
        sub.active = false;
        emit SubscriptionCanceled(id, msg.sender);
    }

    function processSubscription(uint256 id)
        external
        onlyKeeperOrSubscriber(id)
    {
        Subscription storage sub = subscriptions[id];
        require(sub.active, "Vault: inactive");
        require(
            block.timestamp >= sub.nextPaymentTime,
            "Vault: too early"
        );

        IERC20 token = IERC20(sub.token);
        require(
            token.allowance(sub.subscriber, address(this)) >= sub.amount,
            "Vault: insufficient allowance"
        );
        require(
            token.balanceOf(sub.subscriber) >= sub.amount,
            "Vault: insufficient balance"
        );

        // `from` is the subscriber recorded at enrolment (msg.sender in
        // createSubscription), not a caller-supplied address; amount + recipient
        // are fixed by the enrolment terms and the keeper cannot change them. This
        // is the pull-payment mechanism, not an arbitrary transfer — the same
        // documented false positive suppressed on the v2 vault + AutoSwapRouter.
        // slither-disable-next-line arbitrary-send-erc20
        bool ok = token.transferFrom(sub.subscriber, sub.recipient, sub.amount);
        require(ok, "Vault: transfer failed");

        sub.nextPaymentTime += sub.periodSeconds;
        if (sub.remainingPayments > 0) {
            sub.remainingPayments -= 1;
            if (sub.remainingPayments == 0) {
                sub.active = false;
            }
        }

        emit SubscriptionProcessed(
            id,
            sub.subscriber,
            sub.recipient,
            sub.token,
            sub.amount,
            block.timestamp
        );
    }
}
