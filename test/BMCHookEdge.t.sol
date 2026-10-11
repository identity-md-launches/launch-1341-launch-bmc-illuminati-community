// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BMCHook} from "../src/BMCHook.sol";
import {BMCSwapRouter} from "../src/BMCSwapRouter.sol";
import {BMCFixture} from "./utils/BMCFixture.sol";

/// @notice A recipient contract that accepts ETH, the way a smart-account community wallet would.
contract AcceptingWallet {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// @notice Adversarial edges of the hook: boundaries of its rates, dust, callers it did not expect,
/// pools it is not attached to, and the brief's real community wallet.
contract BMCHookEdgeTest is BMCFixture {
    /// @dev The community wallet named in the brief.
    address constant COMMUNITY_WALLET = 0x83027AD9d0D5374335086c539dADD1db983441B0;
    uint128 constant LIQUIDITY = 1e22;

    PoolSwapTest swapRouter;

    function setUp() public {
        deployCore();
        initializePool();
        addFullRangeLiquidity(LIQUIDITY, 1.1 ether);
        fundTrader(10 ether, 10_000_000 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev A second hook on the same manager and token, with its own pool (different tick spacing so
    /// the pool id differs), seeded full range.
    function openPoolWith(address recipient, uint256 buyBps, uint256 sellBps)
        internal
        returns (BMCHook h, PoolKey memory k)
    {
        h = BMCHook(deployHook(address(manager), address(token), recipient, buyBps, sellBps));
        k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: 10,
            hooks: IHooks(address(h))
        });
        manager.initialize(k, OPENING_SQRT_PRICE);
        token.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), address(this).balance + 1.1 ether);
        lpRouter.modifyLiquidity{value: 1.1 ether}(
            k, ModifyLiquidityParams(-887_270, 887_270, int256(uint256(LIQUIDITY)), 0), ""
        );
    }

    // ------------------------------------------------------------------ constructor boundaries

    function test_constructorAcceptsTheCapExactly() public {
        BMCHook h = BMCHook(deployHook(address(manager), address(token), feeRecipient, 5_000, 5_000));
        assertEq(h.buyFeeBps(), 5_000);
        assertEq(h.sellBurnBps(), 5_000);
    }

    function testFuzz_constructorRejectsAnyRateAboveTheCap(uint256 buyBps, uint256 sellBps) public {
        buyBps = bound(buyBps, 5_001, type(uint256).max);
        sellBps = bound(sellBps, 0, 5_000);
        bytes memory code = abi.encodePacked(
            type(BMCHook).creationCode, abi.encode(address(manager), address(token), feeRecipient, buyBps, sellBps)
        );
        // Rate validation runs before the address-bit check, so a plain CREATE reports it.
        vm.expectRevert(BMCHook.RateTooHigh.selector);
        this.create(code);
        code = abi.encodePacked(
            type(BMCHook).creationCode, abi.encode(address(manager), address(token), feeRecipient, sellBps, buyBps)
        );
        vm.expectRevert(BMCHook.RateTooHigh.selector);
        this.create(code);
    }

    function create(bytes memory code) external returns (address at) {
        assembly ("memory-safe") {
            at := create(0, add(code, 0x20), mload(code))
            if iszero(at) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    // ------------------------------------------------------------------ the brief's wallet

    function test_buyFeeReachesTheBriefsCommunityWallet() public {
        (BMCHook h, PoolKey memory k) = openPoolWith(COMMUNITY_WALLET, 100, 100);
        uint256 before = COMMUNITY_WALLET.balance;
        vm.prank(trader);
        router.buyExactIn{value: 0.2 ether}(k, 0);
        assertEq(COMMUNITY_WALLET.balance - before, 0.002 ether, "1% of the ETH side went to 0x8302...41B0");
        assertEq(h.feeRecipient(), COMMUNITY_WALLET);
        assertEq(h.totalEthFeesPaid(), 0.002 ether);
    }

    function test_buyFeeReachesAContractWalletThatAcceptsEth() public {
        AcceptingWallet wallet = new AcceptingWallet();
        (, PoolKey memory k) = openPoolWith(address(wallet), 100, 100);
        vm.prank(trader);
        router.buyExactIn{value: 1 ether}(k, 0);
        assertEq(wallet.received(), 0.01 ether);
    }

    // ------------------------------------------------------------------ zero rates

    function test_zeroRatesChargeNothingAndDoNotAlterTheSwap() public {
        (BMCHook h, PoolKey memory k) = openPoolWith(feeRecipient, 0, 0);
        uint256 supply = token.totalSupply();
        vm.startPrank(trader);
        uint256 out = router.buyExactIn{value: 0.5 ether}(k, 0);
        router.sellExactIn(k, out, 0);
        router.buyExactOut{value: 1 ether}(k, 1_000 ether);
        router.sellExactOut(k, 0.0001 ether, 1_000_000 ether);
        vm.stopPrank();
        assertEq(feeRecipient.balance, 0);
        assertEq(token.totalSupply(), supply);
        assertEq(h.pendingEthFees(), 0);
        assertEq(h.pendingBurns(), 0);
        assertEq(h.totalEthFeesPaid(), 0);
        assertEq(h.totalTokensBurned(), 0);
    }

    // ------------------------------------------------------------------ dust

    /// @dev Floor rounding: an input under 100 wei owes no fee and the swap still goes through.
    function test_dustBuyBelowOneHundredWeiPaysNoFeeAndDoesNotRevert() public {
        vm.prank(trader);
        router.buyExactIn{value: 99}(key, 0);
        assertEq(feeRecipient.balance, 0);
        assertEq(hook.pendingEthFees(), 0);
    }

    function test_smallestChargedBuyPaysOneWei() public {
        vm.prank(trader);
        router.buyExactIn{value: 100}(key, 0);
        assertEq(feeRecipient.balance, 1);
    }

    function test_dustSellBelowOneHundredWeiBurnsNothingAndDoesNotRevert() public {
        uint256 supply = token.totalSupply();
        vm.prank(trader);
        router.sellExactIn(key, 99, 0);
        assertEq(token.totalSupply(), supply);
    }

    // ------------------------------------------------------------------ exact-output fuzz

    function testFuzz_buyExactOutput_feeIsOnePercentOfThePoolsEth(uint256 tokensOut) public {
        tokensOut = bound(tokensOut, 1e12, 20_000_000 ether);
        uint256 managerBefore = address(manager).balance;
        vm.prank(trader);
        uint256 ethIn = router.buyExactOut{value: 5 ether}(key, tokensOut);
        uint256 fee = feeRecipient.balance;
        uint256 poolEth = address(manager).balance - managerBefore;
        assertEq(fee, (poolEth * BUY_FEE_BPS) / 10_000, "fee = floor(1% of the ETH the pool charged)");
        assertEq(ethIn, poolEth + fee, "the buyer paid pool price + fee, nothing else");
        assertEq(token.balanceOf(trader), 10_000_000 ether + tokensOut);
    }

    function testFuzz_sellExactOutput_burnIsOnePercentOfThePoolsTokens(uint256 ethOut) public {
        ethOut = bound(ethOut, 1e9, 0.05 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 managerBefore = token.balanceOf(address(manager));
        vm.prank(trader);
        uint256 tokensIn = router.sellExactOut(key, ethOut, 10_000_000 ether);
        uint256 burned = supplyBefore - token.totalSupply();
        uint256 poolTokens = token.balanceOf(address(manager)) - managerBefore;
        assertEq(burned, (poolTokens * SELL_BURN_BPS) / 10_000);
        assertEq(tokensIn, poolTokens + burned);
        assertEq(trader.balance, 10 ether + ethOut);
    }

    /// @dev The hook's rule against the rate it was built with, for any rate up to the cap.
    function testFuzz_ratesAreAppliedAsConfigured(uint256 buyBps, uint256 sellBps, uint256 ethIn) public {
        buyBps = bound(buyBps, 0, 5_000);
        sellBps = bound(sellBps, 0, 5_000);
        ethIn = bound(ethIn, 1e6, 1 ether);
        (BMCHook h, PoolKey memory k) = openPoolWith(feeRecipient, buyBps, sellBps);

        vm.prank(trader);
        uint256 out = router.buyExactIn{value: ethIn}(k, 0);
        assertEq(feeRecipient.balance, (ethIn * buyBps) / 10_000);

        uint256 supply = token.totalSupply();
        vm.prank(trader);
        router.sellExactIn(k, out, 0);
        assertEq(supply - token.totalSupply(), (out * sellBps) / 10_000);
        assertEq(h.pendingEthFees() + h.pendingBurns(), 0);
    }

    // ------------------------------------------------------------------ pools the hook is not on

    function test_aHooklessBmcPoolIsUntouched() public {
        PoolKey memory k = key;
        k.hooks = IHooks(address(0));
        manager.initialize(k, OPENING_SQRT_PRICE);
        vm.deal(address(this), address(this).balance + 1.1 ether);
        lpRouter.modifyLiquidity{value: 1.1 ether}(
            k, ModifyLiquidityParams(MIN_USABLE_TICK, MAX_USABLE_TICK, int256(uint256(LIQUIDITY)), 0), ""
        );
        uint256 supply = token.totalSupply();
        vm.startPrank(trader);
        uint256 out = router.buyExactIn{value: 0.1 ether}(k, 0);
        router.sellExactIn(k, out, 0);
        vm.stopPrank();
        assertEq(feeRecipient.balance, 0);
        assertEq(token.totalSupply(), supply);
        assertEq(hook.totalEthFeesPaid(), 0);
    }

    function test_hookCannotBeAttachedToAnyOtherPoolAfterItsOwn() public {
        PoolKey memory k = key;
        k.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(k, OPENING_SQRT_PRICE);
        // Even the pool manager calling the callback directly is refused once a pool is attached.
        vm.prank(address(manager));
        vm.expectRevert(BMCHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), k, OPENING_SQRT_PRICE);
    }

    function test_hookBuiltForAnotherManagerRefusesThisOne() public {
        // A hook bound to a different manager address rejects callbacks from this manager.
        BMCHook other = BMCHook(deployHook(makeAddr("otherManager"), address(token), feeRecipient, 100, 100));
        PoolKey memory k = key;
        k.hooks = IHooks(address(other));
        vm.expectRevert();
        manager.initialize(k, OPENING_SQRT_PRICE);
    }

    // ------------------------------------------------------------------ hookData and third-party routers

    function test_hookDataCannotSwitchTheFeeOff() public {
        vm.deal(address(this), 1 ether);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint256(0), address(this), true)
        );
        assertEq(feeRecipient.balance, 0.01 ether);
    }

    function test_feeAppliesThroughAnyRouterNotOnlyOurs() public {
        uint256 supply = token.totalSupply();
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams(false, -1_000_000 ether, TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(supply - token.totalSupply(), 10_000 ether, "1% of the sale burned via a third-party router");
    }

    function test_swapperCanSettleWithClaimsAndStillPaysTheFee() public {
        // Take the output as ERC-6909 claims instead of tokens: the burn and fee rules still apply.
        vm.deal(address(this), 1 ether);
        BalanceDelta d = swapRouter.swap{value: 0.5 ether}(
            key, SwapParams(true, -0.5 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(true, false), ""
        );
        assertGt(d.amount1(), 0);
        assertEq(feeRecipient.balance, 0.005 ether);
        assertEq(manager.balanceOf(address(this), Currency.wrap(address(token)).toId()), uint128(d.amount1()));
    }

    // ------------------------------------------------------------------ collect / unlock surface

    function test_collectCannotBeCalledWhileTheManagerIsUnlocked() public {
        // Re-entering collect from inside another unlock reverts (AlreadyUnlocked): there is no
        // window to redeem claims mid-swap.
        Reenterer r = new Reenterer(IPoolManager(address(manager)), hook);
        vm.expectRevert();
        r.go();
    }

    function test_collectTwiceIsIdempotent() public {
        vm.prank(trader);
        router.buyExactIn{value: 0.1 ether}(key, 0);
        hook.collect();
        hook.collect();
        assertEq(feeRecipient.balance, 0.001 ether, "no double payment");
    }

    function test_hookRejectsPlainEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "the hook has no receive and cannot accumulate ETH");
    }

    function test_strangerCannotBurnTheHooksClaims() public {
        // Claims belong to the hook; nobody else can burn or move them out.
        vm.expectRevert();
        manager.transferFrom(address(hook), address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), 1);
    }
}

/// @dev Calls hook.collect() from inside an unlock callback.
contract Reenterer {
    IPoolManager immutable manager;
    BMCHook immutable hook;

    constructor(IPoolManager m, BMCHook h) {
        manager = m;
        hook = h;
    }

    function go() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        hook.collect();
        return "";
    }
}
