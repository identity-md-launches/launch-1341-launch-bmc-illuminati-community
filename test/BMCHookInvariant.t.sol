// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BMCToken} from "../src/BMCToken.sol";
import {BMCHook} from "../src/BMCHook.sol";
import {BMCSwapRouter} from "../src/BMCSwapRouter.sol";
import {BMCFixture} from "./utils/BMCFixture.sol";

/// @notice Drives the pool through the ownerless router in random order: buys and sells, exact in
/// and exact out, collects and plain transfers, from several traders. Every swap is checked against
/// the fee rule as it happens; anything the rule does not explain is counted as a violation.
contract BMCHookHandler is Test {
    uint256 constant BPS = 10_000;

    PoolManager public manager;
    BMCToken public token;
    BMCHook public hook;
    BMCSwapRouter public router;
    PoolKey key;
    address public feeRecipient;

    address[] public actors;

    // Ghosts: what the rule says should have been charged so far.
    uint256 public ghostExpectedEthFees;
    uint256 public ghostExpectedBurns;
    uint256 public ghostLastSupply;
    uint256 public ghostFeeViolations;
    uint256 public ghostSupplyIncreases;
    uint256 public ghostCollectLeftovers;
    uint256 public ghostSwaps;
    /// @dev Exact-output swaps that succeeded while delivering less than requested. A router defect,
    /// reported in .imd-findings.json (BMCSwapRouter exact-output partial fill); counted, not asserted,
    /// so it does not hide the hook's own invariants.
    uint256 public ghostExactOutShortfalls;
    /// @dev Exact-input swaps the pool only partly filled. The hook still charges 1% of the full amount
    /// specified (reported in .imd-findings.json); their fee is counted in the ghosts as charged but
    /// not checked against a rule, so this suite neither blesses nor hides it.
    uint256 public ghostExactInPartialFills;
    mapping(bytes32 => uint256) public calls;

    constructor(
        PoolManager _manager,
        BMCToken _token,
        BMCHook _hook,
        BMCSwapRouter _router,
        PoolKey memory _key,
        address _feeRecipient
    ) {
        manager = _manager;
        token = _token;
        hook = _hook;
        router = _router;
        key = _key;
        feeRecipient = _feeRecipient;
        ghostLastSupply = token.totalSupply();
        for (uint256 i = 0; i < 3; i++) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            vm.prank(a);
            token.approve(address(router), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _ethCharged() internal view returns (uint256) {
        return feeRecipient.balance + hook.pendingEthFees();
    }

    function _tokensCharged() internal view returns (uint256) {
        return hook.totalTokensBurned() + hook.pendingBurns();
    }

    function _afterCall() internal {
        uint256 supply = token.totalSupply();
        if (supply > ghostLastSupply) ghostSupplyIncreases++;
        ghostLastSupply = supply;
    }

    // ------------------------------------------------------------------ swaps

    function buyExactIn(uint256 seed, uint256 ethIn) external {
        calls["buyExactIn"]++;
        address a = _actor(seed);
        ethIn = bound(ethIn, 1, 3 ether);
        vm.deal(a, a.balance + ethIn);
        uint256 chargedBefore = _ethCharged();
        uint256 burnsBefore = _tokensCharged();
        uint256 actorEthBefore = a.balance;
        vm.prank(a);
        try router.buyExactIn{value: ethIn}(key, 0) {
            uint256 fee = _ethCharged() - chargedBefore;
            if (actorEthBefore - a.balance != ethIn) {
                ghostExactInPartialFills++;
            } else if (fee != (ethIn * hook.buyFeeBps()) / BPS) {
                ghostFeeViolations++;
            }
            if (_tokensCharged() != burnsBefore) ghostFeeViolations++;
            ghostExpectedEthFees += fee;
            ghostSwaps++;
        } catch {}
        _afterCall();
    }

    function buyExactOut(uint256 seed, uint256 tokensOut) external {
        calls["buyExactOut"]++;
        address a = _actor(seed);
        tokensOut = bound(tokensOut, 1, 50_000_000 ether);
        vm.deal(a, a.balance + 10 ether);
        uint256 chargedBefore = _ethCharged();
        uint256 burnsBefore = _tokensCharged();
        uint256 tokensBefore = token.balanceOf(a);
        vm.prank(a);
        try router.buyExactOut{value: 10 ether}(key, tokensOut) returns (uint256 ethIn) {
            uint256 fee = _ethCharged() - chargedBefore;
            uint256 expected = ((ethIn - fee) * hook.buyFeeBps()) / BPS;
            if (fee != expected || _tokensCharged() != burnsBefore) ghostFeeViolations++;
            if (token.balanceOf(a) - tokensBefore != tokensOut) ghostExactOutShortfalls++;
            ghostExpectedEthFees += fee;
            ghostSwaps++;
        } catch {}
        _afterCall();
    }

    function sellExactIn(uint256 seed, uint256 tokensIn) external {
        calls["sellExactIn"]++;
        address a = _actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        tokensIn = bound(tokensIn, 1, bal);
        uint256 burnsBefore = _tokensCharged();
        uint256 ethBefore = _ethCharged();
        vm.prank(a);
        try router.sellExactIn(key, tokensIn, 0) {
            uint256 burned = _tokensCharged() - burnsBefore;
            if (token.balanceOf(a) != bal - tokensIn) {
                ghostExactInPartialFills++;
            } else if (burned != (tokensIn * hook.sellBurnBps()) / BPS) {
                ghostFeeViolations++;
            }
            if (_ethCharged() != ethBefore) ghostFeeViolations++;
            ghostExpectedBurns += burned;
            ghostSwaps++;
        } catch {}
        _afterCall();
    }

    function sellExactOut(uint256 seed, uint256 ethOut) external {
        calls["sellExactOut"]++;
        address a = _actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        ethOut = bound(ethOut, 1, 0.5 ether);
        uint256 burnsBefore = _tokensCharged();
        uint256 ethBefore = _ethCharged();
        uint256 actorEthBefore = a.balance;
        vm.prank(a);
        try router.sellExactOut(key, ethOut, bal) returns (uint256 tokensIn) {
            uint256 burned = _tokensCharged() - burnsBefore;
            uint256 expected = ((tokensIn - burned) * hook.sellBurnBps()) / BPS;
            if (burned != expected || _ethCharged() != ethBefore) ghostFeeViolations++;
            if (a.balance - actorEthBefore != ethOut) ghostExactOutShortfalls++;
            ghostExpectedBurns += burned;
            ghostSwaps++;
        } catch {}
        _afterCall();
    }

    // ------------------------------------------------------------------ everything else anyone can do

    function collect(uint256 seed) external {
        calls["collect"]++;
        vm.prank(_actor(seed));
        hook.collect();
        // After a collect, a claim can only remain where the manager's balance cannot cover it.
        if (hook.pendingEthFees() > 0 && address(manager).balance > 0) ghostCollectLeftovers++;
        if (hook.pendingBurns() > 0 && token.balanceOf(address(manager)) > 0) ghostCollectLeftovers++;
        _afterCall();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls["transfer"]++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal);
        vm.prank(from);
        token.transfer(to, amount);
        _afterCall();
    }

    function warp(uint256 secs) external {
        calls["warp"]++;
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
        vm.roll(block.number + 1);
    }
}

/// @notice The invariants, shared by every pool shape below.
abstract contract BMCHookInvariantBase is BMCFixture {
    BMCHookHandler handler;

    function setUpHandler() internal {
        handler = new BMCHookHandler(manager, token, hook, router, key, feeRecipient);
        // Give the traders something to sell from the start.
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            token.transfer(handler.actors(i), 5_000_000 ether);
        }
        targetContract(address(handler));
        excludeSender(address(manager));
        excludeSender(address(hook));
    }

    /// @dev Every ETH fee that reached the wallet is accounted for, and nothing else reached it.
    function invariant_walletReceivedExactlyWhatTheHookPaid() public view {
        assertEq(feeRecipient.balance, hook.totalEthFeesPaid());
    }

    /// @dev Paid plus still-pending equals what the 1% rule charged over every swap.
    function invariant_ethFeesMatchTheRule() public view {
        assertEq(hook.totalEthFeesPaid() + hook.pendingEthFees(), handler.ghostExpectedEthFees());
    }

    /// @dev The supply only ever falls, and only by what the hook burned.
    function invariant_supplyFallsOnlyByBurns() public view {
        assertEq(token.INITIAL_SUPPLY() - token.totalSupply(), hook.totalTokensBurned());
        assertEq(handler.ghostSupplyIncreases(), 0, "the supply increased");
    }

    function invariant_burnsMatchTheRule() public view {
        assertEq(hook.totalTokensBurned() + hook.pendingBurns(), handler.ghostExpectedBurns());
    }

    function invariant_everySwapFollowedTheRule() public view {
        assertEq(handler.ghostFeeViolations(), 0);
    }

    /// @dev Neither the hook nor the router keeps anything between transactions.
    function invariant_hookAndRouterHoldNothing() public view {
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    /// @dev Pending claims are backed by what the manager holds.
    function invariant_claimsAreBacked() public view {
        assertGe(address(manager).balance, hook.pendingEthFees());
        assertGe(token.balanceOf(address(manager)), hook.pendingBurns());
    }

    function invariant_collectLeavesOnlyUncoverableClaims() public view {
        assertEq(handler.ghostCollectLeftovers(), 0);
    }

    /// @dev Every BMC that exists is held by someone this test knows about: no hidden mint.
    function invariant_balancesSumToSupply() public view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(address(hook)) + token.balanceOf(address(router)) + token.balanceOf(address(lpRouter))
            + token.balanceOf(address(handler)) + token.balanceOf(feeRecipient);
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// @dev Nobody can change the hook's terms.
    function invariant_termsAreImmutable() public view {
        assertEq(hook.feeRecipient(), feeRecipient);
        assertEq(hook.buyFeeBps(), BUY_FEE_BPS);
        assertEq(hook.sellBurnBps(), SELL_BURN_BPS);
        assertEq(hook.token(), address(token));
        assertEq(address(hook.poolManager()), address(manager));
        assertTrue(hook.poolInitialized());
    }
}

/// @notice A pool with liquidity on both sides: fees are paid straight out.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
contract BMCHookInvariantFundedPool is BMCHookInvariantBase {
    function setUp() public {
        deployCore();
        initializePool();
        addFullRangeLiquidity(1e22, 1.1 ether);
        setUpHandler();
    }

    function invariant_someSwapsHappen() public view {
        // Not a property of the hook: guards against a handler whose every call reverts.
        assertTrue(handler.ghostSwaps() > 0 || handler.calls("buyExactIn") == 0);
    }
}

/// @notice The launch's shape: a fresh manager, pool seeded with BMC only. Early buy fees become claims.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
contract BMCHookInvariantTokenOnlyPool is BMCHookInvariantBase {
    function setUp() public {
        deployCore();
        initializePool();
        addTokenOnlyLiquidity(1e22);
        setUpHandler();
    }
}

/// @notice A pool seeded with ETH only: early sell burns become claims.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
contract BMCHookInvariantEthOnlyPool is BMCHookInvariantBase {
    function setUp() public {
        deployCore();
        initializePool();
        addEthOnlyLiquidity(1e22, 1.1 ether);
        setUpHandler();
    }
}
