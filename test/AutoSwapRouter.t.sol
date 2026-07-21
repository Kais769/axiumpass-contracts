// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AutoSwapRouter} from "../src/AutoSwapRouter.sol";
import {MockERC20, MockAggregator, ReentrantAggregator} from "./mocks/Mocks.sol";

/// @notice Aggressive, production-grade security suite for AutoSwapRouter.
/// @dev Post-F1: the swap output is delivered to the ROUTER (receiver = the
///      router in swapData) and force-forwarded to the merchant on-chain, so the
///      keeper can never redirect the payee. Test swapData therefore targets the
///      router as receiver; the drain test proves an attacker receiver reverts.
contract AutoSwapRouterTest is Test {
    AutoSwapRouter internal router;
    MockAggregator internal oneInch;
    MockERC20 internal weth; // input token
    MockERC20 internal usdc; // destination stablecoin

    address internal owner = address(this);
    address internal keeper = makeAddr("keeper");
    address internal merchant = makeAddr("merchant");

    uint256 internal ruleId;

    function setUp() public {
        oneInch = new MockAggregator();
        router = new AutoSwapRouter(address(oneInch), keeper);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        router.setAllowedStable(address(usdc), true);

        // Merchant signs ONCE: approve + create rule.
        vm.startPrank(merchant);
        weth.mint(merchant, 100 ether);
        weth.approve(address(router), type(uint256).max);
        ruleId = router.createRule(address(weth), address(usdc), 10 ether, 0);
        vm.stopPrank();

        // 1 WETH -> 1600 USDC (6 decimals).  rate = 1600e6 / 1e18.
        oneInch.setRate(1600 * 1e6, 1e18);
    }

    /// swapData whose output receiver is the router itself (the required shape).
    function _swapData(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            MockAggregator.swap.selector, address(weth), address(usdc), amount, address(router)
        );
    }

    /// swapData that a compromised keeper would craft: output to an arbitrary receiver.
    function _swapDataTo(uint256 amount, address receiver) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            MockAggregator.swap.selector, address(weth), address(usdc), amount, receiver
        );
    }

    // ───── HAPPY PATH ────────────────────────────────────────────────────────
    function test_ExecuteSwap_ForwardsStableToMerchant() public {
        uint256 amount = 1 ether;
        uint256 expectedOut = 1600 * 1e6;

        vm.prank(keeper);
        router.executeSwap(ruleId, amount, expectedOut, _swapData(amount));

        assertEq(usdc.balanceOf(merchant), expectedOut, "merchant got USDC");
        assertEq(weth.balanceOf(merchant), 99 ether, "merchant WETH debited");
        // Non-custody invariant: the router holds nothing.
        assertEq(weth.balanceOf(address(router)), 0, "router holds no WETH");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no USDC");
    }

    // ───── F1: KEEPER CANNOT DIVERT THE PAYEE ─────────────────────────────────
    function test_CompromisedKeeper_CannotDivertOutput() public {
        address attacker = makeAddr("attacker");
        uint256 amount = 1 ether;

        // Compromised keeper routes the swap output to itself and sets a dust
        // minOut to try to slip past the circuit breaker. The router measures its
        // OWN delta (0, since output went to the attacker) and reverts.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AutoSwapRouter.MinOutNotMet.selector, 0, 1));
        router.executeSwap(ruleId, amount, 1, _swapDataTo(amount, attacker));

        // Atomic revert: nothing moved.
        assertEq(weth.balanceOf(merchant), 100 ether, "merchant WETH intact");
        assertEq(usdc.balanceOf(attacker), 0, "attacker received nothing");
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_MinOutZero_Rejected() public {
        vm.prank(keeper);
        vm.expectRevert(AutoSwapRouter.ZeroMinOut.selector);
        router.executeSwap(ruleId, 1 ether, 0, _swapData(1 ether));
    }

    // ───── ACCESS CONTROL ─────────────────────────────────────────────────────
    function test_OnlyKeeper_CanExecute() public {
        vm.prank(merchant);
        vm.expectRevert(AutoSwapRouter.NotKeeper.selector);
        router.executeSwap(ruleId, 1 ether, 1, _swapData(1 ether));
    }

    function testFuzz_NonKeeperCannotExecute(address caller) public {
        vm.assume(caller != keeper);
        vm.prank(caller);
        vm.expectRevert(AutoSwapRouter.NotKeeper.selector);
        router.executeSwap(ruleId, 1 ether, 1, _swapData(1 ether));
    }

    function testFuzz_OnlyOwnerAdmin(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        router.setKeeper(caller);
    }

    // ───── OWNERSHIP (F14: two-step, renounce disabled) ───────────────────────
    function test_OwnershipTransfer_TwoStep() public {
        address next = makeAddr("newOwner");
        router.transferOwnership(next); // proposes; owner unchanged until accepted
        assertEq(router.owner(), owner, "owner unchanged until accepted");

        vm.prank(makeAddr("intruder"));
        vm.expectRevert(); // only the pending owner may accept
        router.acceptOwnership();

        vm.prank(next);
        router.acceptOwnership();
        assertEq(router.owner(), next);
    }

    function test_RenounceOwnership_Disabled() public {
        vm.expectRevert("Router: renounce disabled");
        router.renounceOwnership();
    }

    // ───── EMERGENCY STOP ─────────────────────────────────────────────────────
    function test_Paused_BlocksExecute_ButNotCancel() public {
        router.pause();

        vm.prank(keeper);
        vm.expectRevert(); // Pausable: EnforcedPause
        router.executeSwap(ruleId, 1 ether, 1, _swapData(1 ether));

        // Merchants can always exit, even while paused.
        vm.prank(merchant);
        router.cancelRule(ruleId);

        // Unpause restores the swap path.
        router.unpause();
        vm.prank(merchant);
        uint256 id = router.createRule(address(weth), address(usdc), 10 ether, 0);
        vm.prank(keeper);
        router.executeSwap(id, 1 ether, 1600 * 1e6, _swapData(1 ether));
        assertEq(usdc.balanceOf(merchant), 1600 * 1e6);
    }

    function testFuzz_Pause_OnlyOwner(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        router.pause();
    }

    // ───── RESCUE (stray funds only) ──────────────────────────────────────────
    function test_RescueToken() public {
        usdc.mint(address(router), 500 * 1e6); // accidental direct transfer
        address treasury = makeAddr("treasury");
        router.rescueToken(address(usdc), treasury);
        assertEq(usdc.balanceOf(treasury), 500 * 1e6);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function testFuzz_RescueToken_OnlyOwner(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        router.rescueToken(address(usdc), caller);
    }

    // ───── CIRCUIT BREAKER / ORACLE FLASH-CRASH ───────────────────────────────
    function test_OracleFlashCrash_RevertsOnMinOut() public {
        // Simulate a flash-crash: the swap now returns only ~0.10 of expected.
        oneInch.setRate(160 * 1e6, 1e18); // 1 WETH -> 160 USDC instead of 1600
        uint256 amount = 1 ether;
        uint256 minOut = 1600 * 1e6; // merchant demands the fair amount

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(AutoSwapRouter.MinOutNotMet.selector, 160 * 1e6, minOut)
        );
        router.executeSwap(ruleId, amount, minOut, _swapData(amount));

        // Nothing moved — funds safe.
        assertEq(usdc.balanceOf(merchant), 0);
        assertEq(weth.balanceOf(merchant), 100 ether);
    }

    function test_OraclePriceSpike_StillHonorsMinOut() public {
        // Spike: merchant simply receives more; minOut still satisfied.
        oneInch.setRate(10_000 * 1e6, 1e18);
        vm.prank(keeper);
        router.executeSwap(ruleId, 1 ether, 1600 * 1e6, _swapData(1 ether));
        assertEq(usdc.balanceOf(merchant), 10_000 * 1e6);
    }

    // ───── REENTRANCY ─────────────────────────────────────────────────────────
    function test_Reentrancy_Blocked() public {
        // Deploy a router whose aggregator reenters executeSwap mid-swap.
        ReentrantAggregator evil = new ReentrantAggregator();
        AutoSwapRouter r2 = new AutoSwapRouter(address(evil), keeper);
        r2.setAllowedStable(address(usdc), true);

        vm.startPrank(merchant);
        weth.approve(address(r2), type(uint256).max);
        uint256 id2 = r2.createRule(address(weth), address(usdc), 10 ether, 0);
        vm.stopPrank();

        evil.configure(r2, id2, _swapData(1 ether));

        // The reentry attempt must cause the whole tx to revert (guard + access).
        vm.prank(keeper);
        vm.expectRevert();
        r2.executeSwap(id2, 1 ether, 1, _swapData(1 ether));

        // No double-spend: merchant balance untouched.
        assertEq(weth.balanceOf(merchant), 100 ether);
    }

    // ───── STATELESS / NON-CUSTODY ───────────────────────────────────────────
    function test_RejectsNativeETH() public {
        // No receive()/fallback() payable → any ETH transfer must revert.
        (bool ok, ) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "contract must reject native ETH");
    }

    function test_LeftoverInput_RevertsAndReturns() public {
        // Aggregator that pulls nothing → input stays in the router → must revert
        // (LeftoverInput) after returning the funds to the merchant.
        BadAggregatorNoop noop = new BadAggregatorNoop();
        AutoSwapRouter r3 = new AutoSwapRouter(address(noop), keeper);
        r3.setAllowedStable(address(usdc), true);
        vm.startPrank(merchant);
        weth.approve(address(r3), type(uint256).max);
        uint256 id3 = r3.createRule(address(weth), address(usdc), 10 ether, 0);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(AutoSwapRouter.LeftoverInput.selector);
        r3.executeSwap(id3, 1 ether, 1, abi.encodeWithSignature("noop()"));
    }

    // ───── RULE CONSTRAINTS ──────────────────────────────────────────────────
    function test_AmountCap_Enforced() public {
        vm.prank(keeper);
        vm.expectRevert(AutoSwapRouter.BadAmount.selector);
        router.executeSwap(ruleId, 11 ether, 1, _swapData(11 ether)); // > 10 cap
    }

    function test_MaxInterval_Enforced() public {
        vm.prank(merchant);
        vm.expectRevert(AutoSwapRouter.BadInterval.selector);
        router.createRule(address(weth), address(usdc), 10 ether, 366 days); // > MAX_INTERVAL
    }

    function test_Interval_Enforced() public {
        vm.prank(merchant);
        uint256 id = router.createRule(address(weth), address(usdc), 10 ether, 1 days);

        vm.prank(keeper);
        router.executeSwap(id, 1 ether, 1, _swapData(1 ether));

        vm.prank(keeper);
        vm.expectRevert(AutoSwapRouter.TooSoon.selector);
        router.executeSwap(id, 1 ether, 1, _swapData(1 ether));
    }

    function test_Cancel_StopsExecution() public {
        vm.prank(merchant);
        router.cancelRule(ruleId);
        vm.prank(keeper);
        vm.expectRevert(AutoSwapRouter.RuleInactive.selector);
        router.executeSwap(ruleId, 1 ether, 1, _swapData(1 ether));
    }

    function test_NonStableDestination_Rejected() public {
        MockERC20 random = new MockERC20("Rand", "RND", 18);
        vm.prank(merchant);
        vm.expectRevert(AutoSwapRouter.StableNotAllowed.selector);
        router.createRule(address(weth), address(random), 1 ether, 0);
    }

    // ───── F3: ON-CHAIN ORACLE FLOOR ──────────────────────────────────────────
    function test_OracleFloor_RevertsBelow_PassesAbove() public {
        // Feed: 1 WETH = $1600 (8-decimal answer). 1% slippage → floor = 1584 USDC.
        MockV3Aggregator feed = new MockV3Aggregator(8, 1600e8);
        vm.prank(merchant);
        router.setRuleFeed(ruleId, address(feed), 100, 1 hours);

        // A bad rate (1500 USDC) clears a dust minOut but not the oracle floor.
        oneInch.setRate(1500 * 1e6, 1e18);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(AutoSwapRouter.BelowOracleFloor.selector, 1500 * 1e6, 1584 * 1e6)
        );
        router.executeSwap(ruleId, 1 ether, 1, _swapData(1 ether));

        // A fair rate (1600 USDC) clears the floor.
        oneInch.setRate(1600 * 1e6, 1e18);
        vm.prank(keeper);
        router.executeSwap(ruleId, 1 ether, 1, _swapData(1 ether));
        assertEq(usdc.balanceOf(merchant), 1600 * 1e6);
    }

    function test_OracleFloor_StaleFeed_Reverts() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 1600e8);
        vm.prank(merchant);
        router.setRuleFeed(ruleId, address(feed), 100, 1 hours);

        vm.warp(block.timestamp + 2 hours); // age the answer past the heartbeat
        oneInch.setRate(1600 * 1e6, 1e18);
        vm.prank(keeper);
        vm.expectRevert(AutoSwapRouter.StaleOrBadFeed.selector);
        router.executeSwap(ruleId, 1 ether, 1, _swapData(1 ether));
    }

    function test_SetRuleFeed_OnlyMerchant() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 1600e8);
        vm.prank(keeper);
        vm.expectRevert(AutoSwapRouter.NotRuleOwner.selector);
        router.setRuleFeed(ruleId, address(feed), 100, 1 hours);
    }

    function test_SetRuleFeed_BadSlippage_Reverts() public {
        vm.prank(merchant);
        vm.expectRevert(AutoSwapRouter.BadSlippage.selector);
        router.setRuleFeed(ruleId, address(0xFEED), 10_001, 1 hours); // > 100%
    }

    // NEW-3: slippage == BPS (100%) would make _oracleFloor collapse to 0,
    // silently disabling the F3 protection while it looks enabled. Rejected too.
    function test_SetRuleFeed_FullSlippage_Reverts() public {
        vm.prank(merchant);
        vm.expectRevert(AutoSwapRouter.BadSlippage.selector);
        router.setRuleFeed(ruleId, address(0xFEED), 10_000, 1 hours); // == 100%
    }
}

/// @notice Aggregator that does nothing → leaves input stuck in the router.
contract BadAggregatorNoop {
    function noop() external {}
}

/// @notice Minimal Chainlink-style feed for the F3 oracle-floor tests.
contract MockV3Aggregator {
    uint8 public decimals;
    int256 internal answer;
    uint256 internal updatedAt;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }
}
