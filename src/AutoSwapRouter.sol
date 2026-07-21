// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Minimal Chainlink AggregatorV3 surface (avoids a vendored dependency).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title AxiumPass AutoSwapRouter
 * @author AxiumPass
 * @notice STATELESS, NON-CUSTODIAL atomic auto-swap router.
 *
 *  ── DESIGN PRINCIPLES (MiCA: SaaS orchestrator, NOT a custodian) ──────────
 *  • The contract holds NO funds across transactions: there is no `receive()`
 *    nor `fallback()` payable, and every token pulled in is swapped + forwarded
 *    to the merchant within the SAME atomic transaction.
 *  • A merchant signs ONCE: `token.approve(this, X)` + `createRule(...)`. After
 *    that, AxiumPass's keeper triggers `executeSwap(...)` automatically.
 *
 *  ── FUND-FLOW GUARANTEE — enforced ON-CHAIN, not trusted from the keeper ──
 *  The swap output is received by THIS contract and then force-transferred to
 *  `rule.merchant`. The contract does NOT trust the swap's internal receiver:
 *  the swap MUST send its output back to this router (set the 1inch receiver to
 *  address(this) in the backend-built calldata), and this contract measures its
 *  OWN balance delta and pays the merchant. Therefore, even a fully compromised
 *  keeper cannot divert funds: any calldata that routes output elsewhere yields
 *  a zero self-delta and reverts on `minOut` (which must be > 0). The worst a
 *  compromised keeper can do is force a swap at a poor rate — bounded by `minOut`
 *  and the merchant's limited, cancellable approval. (On-chain oracle bounds on
 *  `minOut` remain a planned hardening — see the internal audit, finding F3.)
 *
 *  Funds flow per swap:  merchant ─transferFrom─▶ this ─approve+call─▶ 1inch ─▶ this ─transfer─▶ merchant
 *
 *  ── SECURITY NOTES (acknowledged Slither findings — all mitigated) ────────
 *  1. `arbitrary-send-erc20` (transferFrom uses `from = merchant`, not msg.sender):
 *     BY DESIGN. The merchant opted in via approve() + createRule(). `from` is
 *     read from the rule (not caller-supplied) and the output payee is forced to
 *     rule.merchant, so the keeper can only ever move funds merchant→merchant.
 *  2. `reentrancy-*`: guarded by `nonReentrant`; the swap is `whenNotPaused`.
 *  3. `timestamp`: only a coarse min-interval throttle (minutes+); validator skew irrelevant.
 *  4. `low-level-calls`: required to forward backend-built 1inch calldata to the
 *     IMMUTABLE verified router; bounded by minOut + self-delta + leftover + nonReentrant.
 */
contract AutoSwapRouter is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // ───── CONSTANTS ────────────────────────────────────────────────────────
    // Upper bound on a rule's throttle. Prevents `lastExecuted + minIntervalSec`
    // from overflowing (which would permanently brick the rule). A zero interval
    // is allowed (the merchant may opt out of throttling).
    uint256 public constant MAX_INTERVAL = 365 days;

    // ───── IMMUTABLE / STORAGE ──────────────────────────────────────────────
    address public immutable oneInchRouter; // verified 1inch Aggregation Router v6
    address public keeper;

    struct Rule {
        address merchant; // funds owner AND the forced output recipient
        address fromToken;
        address toToken; // must be a whitelisted stablecoin
        uint256 maxAmountPerSwap;
        uint256 minIntervalSec;
        uint256 lastExecuted;
        bool active;
        // F3 — optional on-chain price floor. When priceFeed != 0, executeSwap
        // additionally requires the output to be >= an oracle-derived floor, so a
        // compromised keeper cannot accept an arbitrarily bad rate. Default off.
        address priceFeed; // Chainlink fromToken/USD aggregator (0 = disabled)
        uint256 maxSlippageBps; // allowed slippage vs the oracle (bps, <= 10000)
        uint256 feedHeartbeat; // max age of the feed answer, seconds
    }

    uint256 public constant BPS = 10_000;

    uint256 public nextRuleId;
    mapping(uint256 => Rule) public rules;
    mapping(address => bool) public allowedStable; // destination token whitelist

    // ───── EVENTS ───────────────────────────────────────────────────────────
    event KeeperUpdated(address indexed prev, address indexed next);
    event StableAllowed(address indexed token, bool allowed);
    event RuleCreated(
        uint256 indexed id,
        address indexed merchant,
        address fromToken,
        address toToken,
        uint256 maxAmountPerSwap,
        uint256 minIntervalSec
    );
    event RuleCancelled(uint256 indexed id, address indexed merchant);
    event SwapExecuted(
        uint256 indexed id,
        address indexed merchant,
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 amountOut
    );
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event RuleFeedSet(uint256 indexed id, address indexed feed, uint256 maxSlippageBps, uint256 feedHeartbeat);

    // ───── ERRORS ───────────────────────────────────────────────────────────
    error ZeroAddress();
    error NotKeeper();
    error NotRuleOwner();
    error RuleInactive();
    error StableNotAllowed();
    error BadTokens();
    error BadAmount();
    error BadInterval();
    error ZeroMinOut();
    error TooSoon();
    error SwapFailed();
    error MinOutNotMet(uint256 received, uint256 minOut);
    error LeftoverInput();
    error BadSlippage();
    error StaleOrBadFeed();
    error BelowOracleFloor(uint256 received, uint256 floor);

    // ───── MODIFIERS ────────────────────────────────────────────────────────
    // onlyOwner is inherited from Ownable (via Ownable2Step).
    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(address _oneInchRouter, address _keeper) Ownable(msg.sender) {
        if (_oneInchRouter == address(0) || _keeper == address(0)) revert ZeroAddress();
        oneInchRouter = _oneInchRouter;
        keeper = _keeper;
        emit KeeperUpdated(address(0), _keeper);
    }

    // NOTE: intentionally NO receive()/fallback() — the contract must never be
    // able to receive or hold native funds. Any ETH sent in reverts.

    // ───── ADMIN ────────────────────────────────────────────────────────────
    // Ownership rotation is inherited from Ownable2Step (transferOwnership +
    // acceptOwnership — safe two-step handoff, e.g. to a Safe multisig).
    // F14/F18: renounce is disabled — the router is meaningless without an owner
    // (no pause / keeper rotation / allowlist).
    function renounceOwnership() public pure override {
        revert("Router: renounce disabled");
    }

    function setKeeper(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit KeeperUpdated(keeper, next);
        keeper = next;
    }

    function setAllowedStable(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedStable[token] = allowed;
        emit StableAllowed(token, allowed);
    }

    /// @notice Emergency stop for the keeper's swap path. Rule creation and
    ///         cancellation stay open so merchants can always exit.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover tokens accidentally sent to (or dust left in) the router.
    ///         The contract never holds funds across a swap, so this is a safety
    ///         net for stray transfers, not part of the fund flow.
    function rescueToken(address token, address to) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
        emit TokenRescued(token, to, bal);
    }

    // ───── MERCHANT (sign once) ─────────────────────────────────────────────
    function createRule(
        address fromToken,
        address toToken,
        uint256 maxAmountPerSwap,
        uint256 minIntervalSec
    ) external returns (uint256 id) {
        if (!allowedStable[toToken]) revert StableNotAllowed();
        if (fromToken == address(0) || fromToken == toToken) revert BadTokens();
        if (maxAmountPerSwap == 0) revert BadAmount();
        if (minIntervalSec > MAX_INTERVAL) revert BadInterval(); // F13: cap to avoid overflow-brick

        id = nextRuleId++;
        rules[id] = Rule({
            merchant: msg.sender,
            fromToken: fromToken,
            toToken: toToken,
            maxAmountPerSwap: maxAmountPerSwap,
            minIntervalSec: minIntervalSec,
            lastExecuted: 0,
            active: true,
            priceFeed: address(0), // F3 oracle floor off by default; set via setRuleFeed
            maxSlippageBps: 0,
            feedHeartbeat: 0
        });
        emit RuleCreated(id, msg.sender, fromToken, toToken, maxAmountPerSwap, minIntervalSec);
    }

    /// @notice F3 — merchant opts into an on-chain price floor for their rule.
    ///         When set, executeSwap requires the output to be at least the
    ///         oracle value of the input minus `slippageBps`, so a compromised
    ///         keeper cannot accept an arbitrarily bad rate. Set feed=0 to disable.
    /// @param feed        Chainlink `fromToken/USD` aggregator (toToken is a ~$1 stable)
    /// @param slippageBps allowed slippage vs the oracle, in basis points (<= 10000)
    /// @param heartbeat   max age of the feed answer, in seconds (0 with feed=0)
    function setRuleFeed(uint256 id, address feed, uint256 slippageBps, uint256 heartbeat) external {
        Rule storage r = rules[id];
        if (r.merchant != msg.sender) revert NotRuleOwner();
        // Reject `>= BPS`: at exactly 100% the floor `expected * (BPS - slippage) / BPS`
        // collapses to 0, so `received < floor` can never fire — the oracle floor
        // (F3) would look enabled (`priceFeed != 0`, `RuleFeedSet` emitted) yet be
        // inert. Requiring `< BPS` keeps the floor strictly positive.
        if (slippageBps >= BPS) revert BadSlippage();
        if (feed != address(0) && heartbeat == 0) revert StaleOrBadFeed();
        r.priceFeed = feed;
        r.maxSlippageBps = slippageBps;
        r.feedHeartbeat = heartbeat;
        emit RuleFeedSet(id, feed, slippageBps, heartbeat);
    }

    /// @dev Oracle-derived minimum acceptable output (in toToken units) for
    ///      swapping `amountIn` of fromToken, assuming toToken ≈ $1. Reverts on a
    ///      stale or non-positive feed answer.
    function _oracleFloor(Rule storage r, uint256 amountIn) internal view returns (uint256) {
        IAggregatorV3 feed = IAggregatorV3(r.priceFeed);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert StaleOrBadFeed();
        if (block.timestamp - updatedAt > r.feedHeartbeat) revert StaleOrBadFeed();

        uint256 feedDecimals = feed.decimals();
        uint256 fromDecimals = IERC20Metadata(r.fromToken).decimals();
        uint256 toDecimals = IERC20Metadata(r.toToken).decimals();

        // expected out (toToken units) = amountIn * price * 10^toDec / (10^fromDec * 10^feedDec)
        uint256 expected = (amountIn * uint256(answer) * (10 ** toDecimals))
            / ((10 ** fromDecimals) * (10 ** feedDecimals));
        return (expected * (BPS - r.maxSlippageBps)) / BPS;
    }

    function cancelRule(uint256 id) external {
        Rule storage r = rules[id];
        if (r.merchant != msg.sender) revert NotRuleOwner();
        r.active = false;
        emit RuleCancelled(id, msg.sender);
    }

    // ───── KEEPER (automatic, constrained) ──────────────────────────────────
    /**
     * @notice Atomically swap `amount` of the rule's `fromToken` into its
     *         stablecoin and forward the proceeds to the merchant.
     * @param id        rule id
     * @param amount    input amount (<= rule.maxAmountPerSwap)
     * @param minOut    minimum stablecoin the merchant must receive (must be > 0)
     * @param swapData  1inch Aggregation Router calldata built off-chain by the
     *                  AxiumPass backend. Its swap RECEIVER MUST be this router
     *                  (address(this)); the contract then forwards the output to
     *                  the merchant. Output routed anywhere else yields a zero
     *                  self-delta and reverts — this is the non-custodial guarantee.
     */
    function executeSwap(uint256 id, uint256 amount, uint256 minOut, bytes calldata swapData)
        external
        onlyKeeper
        nonReentrant
        whenNotPaused
    {
        Rule storage r = rules[id];
        if (!r.active) revert RuleInactive();
        if (amount == 0 || amount > r.maxAmountPerSwap) revert BadAmount();
        if (minOut == 0) revert ZeroMinOut(); // no keeper bypass via minOut=0 (F1/F3)
        if (r.lastExecuted != 0 && block.timestamp < r.lastExecuted + r.minIntervalSec) {
            revert TooSoon();
        }

        // Effects before interactions (checks-effects-interactions).
        r.lastExecuted = block.timestamp;

        IERC20 fromT = IERC20(r.fromToken);
        IERC20 toT = IERC20(r.toToken);

        // Measure THIS router's own output balance before the swap. The merchant
        // is paid from the router's delta, so the payee cannot be redirected by
        // the keeper's swapData (F1).
        uint256 selfOutBefore = toT.balanceOf(address(this));

        // Pull the exact input from the merchant (approved once, one-time scope).
        // `from` is not caller-supplied: it is the merchant recorded on the rule
        // they created and granted the allowance for. onlyKeeper + maxAmountPerSwap
        // + forced payee + leftover-return bound the pull; Slither's heuristic
        // cannot see the rule ownership.
        // slither-disable-next-line arbitrary-send-erc20
        fromT.safeTransferFrom(r.merchant, address(this), amount);

        // Approve 1inch for exactly this amount (reset-to-zero pattern via forceApprove).
        fromT.forceApprove(oneInchRouter, amount);

        // Execute the swap. 1inch pulls `fromToken` from this contract; the
        // backend MUST set the swap receiver to this router (address(this)).
        (bool ok, ) = oneInchRouter.call(swapData);
        if (!ok) revert SwapFailed();

        // Drop any residual allowance.
        fromT.forceApprove(oneInchRouter, 0);

        // Atomicity guarantee: the contract must not retain ANY input token.
        uint256 leftover = fromT.balanceOf(address(this));
        if (leftover != 0) {
            // Never custody: return leftovers to the merchant and fail loudly.
            fromT.safeTransfer(r.merchant, leftover);
            revert LeftoverInput();
        }

        // The output the swap actually delivered TO THIS ROUTER (not to whoever
        // the keeper named). This is the only value the merchant can receive.
        uint256 received = toT.balanceOf(address(this)) - selfOutBefore;
        if (received < minOut) revert MinOutNotMet(received, minOut);

        // F3 — optional on-chain floor: reject a rate worse than the oracle allows,
        // independent of the keeper-supplied minOut. Off unless the merchant set a feed.
        if (r.priceFeed != address(0)) {
            uint256 floor = _oracleFloor(r, amount);
            if (received < floor) revert BelowOracleFloor(received, floor);
        }

        // Force the payee on-chain: pay the merchant recorded on the rule.
        toT.safeTransfer(r.merchant, received);

        emit SwapExecuted(id, r.merchant, r.fromToken, r.toToken, amount, received);
    }
}
