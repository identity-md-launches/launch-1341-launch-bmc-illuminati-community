// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BMCHook, BMC_HOOK_FLAGS} from "../src/BMCHook.sol";
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

    uint256 hooksPlaced;

    /// @dev Places a hook at a fresh address that carries exactly the hook's flag bits by running its
    /// constructor in place (the protected floor does the same for the PoolManager). Mining a CREATE2
    /// salt per fuzz run is not an option: fuzzed rates change the init code, and an unlucky search
    /// runs out of memory long before `HookDeployer`'s 500,000 tries. The constructor still validates
    /// the address bits, so what is placed is what the launch deployer would place.
    function placeHook(address recipient, uint256 buyBps, uint256 sellBps) internal returns (BMCHook) {
        bytes memory creationCode = abi.encodePacked(
            type(BMCHook).creationCode, abi.encode(address(manager), address(token), recipient, buyBps, sellBps)
        );
        address at = address(
            (uint160(uint256(keccak256(abi.encode("placed hook", hooksPlaced++)))) & ~Hooks.ALL_HOOK_MASK)
                | BMC_HOOK_FLAGS
        );
        vm.etch(at, creationCode);
        (bool built, bytes memory runtime) = at.call("");
        require(built, "hook constructor reverted");
        vm.etch(at, runtime);
        return BMCHook(at);
    }

    /// @dev A second hook on the same manager and token, with its own pool (different tick spacing so
    /// the pool id differs), seeded full range.
    function openPoolWith(address recipient, uint256 buyBps, uint256 sellBps)
        internal
        returns (BMCHook h, PoolKey memory k)
    {
        h = placeHook(recipient, buyBps, sellBps);
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

    /// @dev Exact output grosses the fee up from the pool's input so it is 1% of what the buyer paid in
    /// total, the same share an exact-input buy pays. Both forms are asserted: the gross-up the hook
    /// computes and the brief's "1% of the ETH side" it is meant to equal.
    function testFuzz_buyExactOutput_feeIsOnePercentOfTotalEthPaid(uint256 tokensOut) public {
        tokensOut = bound(tokensOut, 1e12, 20_000_000 ether);
        uint256 managerBefore = address(manager).balance;
        vm.prank(trader);
        uint256 ethIn = router.buyExactOut{value: 5 ether}(key, tokensOut);
        uint256 fee = feeRecipient.balance;
        uint256 poolEth = address(manager).balance - managerBefore;
        assertEq(fee, (poolEth * BUY_FEE_BPS) / (10_000 - BUY_FEE_BPS), "fee = pool ETH grossed up to 1% of total");
        assertEq(fee, (ethIn * BUY_FEE_BPS) / 10_000, "fee = floor(1% of the total ETH paid)");
        assertEq(ethIn, poolEth + fee, "the buyer paid pool price + fee, nothing else");
        assertEq(token.balanceOf(trader), 10_000_000 ether + tokensOut, "exact output delivered in full");
    }

    function testFuzz_sellExactOutput_burnIsOnePercentOfTotalTokensPaid(uint256 ethOut) public {
        ethOut = bound(ethOut, 1e9, 0.05 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 managerBefore = token.balanceOf(address(manager));
        vm.prank(trader);
        uint256 tokensIn = router.sellExactOut(key, ethOut, 10_000_000 ether);
        uint256 burned = supplyBefore - token.totalSupply();
        uint256 poolTokens = token.balanceOf(address(manager)) - managerBefore;
        assertEq(burned, (poolTokens * SELL_BURN_BPS) / (10_000 - SELL_BURN_BPS));
        assertEq(burned, (tokensIn * SELL_BURN_BPS) / 10_000, "burn = floor(1% of the total BMC paid)");
        assertEq(tokensIn, poolTokens + burned);
        assertEq(trader.balance, 10 ether + ethOut, "exact output delivered in full");
    }

    /// @dev The gross-up holds at every rate up to the cap, where the fee equals the pool's input
    /// (50% of the total). Exact output and exact input then charge the same share of total input.
    function testFuzz_exactOutputChargesTheRateOnTotalInputForAnyRate(uint256 buyBps, uint256 sellBps, uint256 out)
        public
    {
        buyBps = bound(buyBps, 1, 5_000);
        sellBps = bound(sellBps, 1, 5_000);
        out = bound(out, 1e9, 1e12);
        (BMCHook h, PoolKey memory k) = openPoolWith(feeRecipient, buyBps, sellBps);

        uint256 managerEthBefore = address(manager).balance;
        vm.prank(trader);
        uint256 ethIn = router.buyExactOut{value: 5 ether}(k, out * 1e6);
        uint256 poolEth = address(manager).balance - managerEthBefore;
        assertEq(feeRecipient.balance, (poolEth * buyBps) / (10_000 - buyBps));
        assertEq(feeRecipient.balance, (ethIn * buyBps) / 10_000, "buy fee is the rate on total ETH");
        if (buyBps == 5_000) assertEq(feeRecipient.balance, poolEth, "at the cap the fee equals the pool's input");

        uint256 supply = token.totalSupply();
        uint256 managerTokBefore = token.balanceOf(address(manager));
        vm.prank(trader);
        uint256 tokensIn = router.sellExactOut(k, out, 10_000_000 ether);
        uint256 poolTokens = token.balanceOf(address(manager)) - managerTokBefore;
        assertEq(supply - token.totalSupply(), (poolTokens * sellBps) / (10_000 - sellBps));
        assertEq(supply - token.totalSupply(), (tokensIn * sellBps) / 10_000, "burn is the rate on total BMC");
        assertEq(h.pendingEthFees() + h.pendingBurns(), 0);
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

    // ------------------------------------------------------------------ exact-input short fills

    /// @dev The revert the PoolManager wraps a failing hook callback in (ERC-7751).
    function wrapped(BMCHook h, bytes4 callback, bytes memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(h),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Splits a wrapped revert into the hook callback that failed and its own revert reason.
    function unwrap(bytes memory err) internal pure returns (address target, bytes4 callback, bytes memory reason) {
        assertEq(bytes4(err), CustomRevert.WrappedError.selector, "not a wrapped hook revert");
        bytes memory details;
        (target, callback, reason, details) = abi.decode(slice(err, 4), (address, bytes4, bytes, bytes));
        assertEq(details, abi.encodeWithSelector(Hooks.HookCallFailed.selector));
    }

    function slice(bytes memory data, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(data.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[i + from];
        }
    }

    /// @dev A buy stopped by a price limit before the pool consumed 99% of the input reverts in
    /// `afterSwap` with `PartialFill(expected, consumed)`, where expected is the input less the fee and
    /// consumed is what the pool actually took: the hook never keeps a fee on ETH that was not traded.
    function test_shortFilledBuyRevertsWithPartialFillNamingBothAmounts() public {
        uint256 amountIn = 1 ether;
        vm.deal(address(this), amountIn);
        try swapRouter.swap{value: amountIn}(
            key,
            SwapParams(true, -int256(amountIn), OPENING_SQRT_PRICE * 999 / 1000),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta
        ) {
            fail("a short fill went through");
        } catch (bytes memory err) {
            (address target, bytes4 callback, bytes memory reason) = unwrap(err);
            assertEq(target, address(hook));
            assertEq(callback, IHooks.afterSwap.selector);
            assertEq(bytes4(reason), BMCHook.PartialFill.selector);
            (uint256 expected, uint256 consumed) = abi.decode(slice(reason, 4), (uint256, uint256));
            assertEq(expected, amountIn - amountIn / 100, "expected = input less the 1% fee");
            assertLt(consumed, expected, "the pool took less than that");
            assertGt(consumed, 0, "and it did trade something before the limit");
        }
        assertEq(feeRecipient.balance, 0, "no fee survived the revert");
        assertEq(hook.pendingEthFees(), 0);
        assertEq(address(this).balance, amountIn, "the router returned every wei");
    }

    function test_shortFilledSaleRevertsWithPartialFillNamingBothAmounts() public {
        uint256 amountIn = 10_000_000 ether;
        token.approve(address(swapRouter), amountIn);
        uint256 supply = token.totalSupply();
        try swapRouter.swap(
            key,
            SwapParams(false, -int256(amountIn), OPENING_SQRT_PRICE * 1001 / 1000),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta
        ) {
            fail("a short fill went through");
        } catch (bytes memory err) {
            (address target, bytes4 callback, bytes memory reason) = unwrap(err);
            assertEq(target, address(hook));
            assertEq(callback, IHooks.afterSwap.selector);
            assertEq(bytes4(reason), BMCHook.PartialFill.selector);
            (uint256 expected, uint256 consumed) = abi.decode(slice(reason, 4), (uint256, uint256));
            assertEq(expected, amountIn - amountIn / 100);
            assertLt(consumed, expected);
            assertGt(consumed, 0);
        }
        assertEq(token.totalSupply(), supply, "nothing burned");
        assertEq(hook.pendingBurns(), 0);
    }

    /// @dev A zero fill (limit at the current price) is the extreme short fill: consumed = 0.
    function test_zeroFillReportsZeroConsumed() public {
        (uint160 price,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), key.toId());
        vm.deal(address(this), 1 ether);
        try swapRouter.swap{value: 1 ether}(
            key, SwapParams(true, -1 ether, price), PoolSwapTest.TestSettings(false, false), ""
        ) returns (
            BalanceDelta
        ) {
            fail("a zero fill went through");
        } catch (bytes memory err) {
            if (bytes4(err) != CustomRevert.WrappedError.selector) {
                // The manager may refuse the limit itself; then the hook was never reached and nothing
                // was charged, which is also acceptable.
                return;
            }
            (,, bytes memory reason) = unwrap(err);
            assertEq(bytes4(reason), BMCHook.PartialFill.selector);
            (, uint256 consumed) = abi.decode(slice(reason, 4), (uint256, uint256));
            assertEq(consumed, 0);
        }
        assertEq(feeRecipient.balance, 0);
    }

    /// @dev Short fills are an exact-input concern only: an exact-output buy stopped by a price limit
    /// simply delivers less, and the fee is 1% of the total the buyer actually paid.
    function test_shortFilledExactOutputBuyPaysTheRateOnWhatWasPaid() public {
        vm.deal(address(this), 5 ether);
        uint256 managerBefore = address(manager).balance;
        BalanceDelta d = swapRouter.swap{value: 5 ether}(
            key,
            SwapParams(true, int256(50_000_000 ether), OPENING_SQRT_PRICE * 999 / 1000),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertLt(uint256(uint128(d.amount1())), 50_000_000 ether, "the limit cut the output short");
        uint256 poolEth = address(manager).balance - managerBefore;
        uint256 paid = poolEth + feeRecipient.balance;
        assertEq(feeRecipient.balance, paid / 100, "1% of the total ETH actually paid");
        assertEq(5 ether - address(this).balance, paid);
    }

    // ------------------------------------------------------------------ the payment window

    /// @dev While the hook pays the recipient the PoolManager is unlocked. A recipient that tries to
    /// trade in that window, in either direction and either swap shape, is refused by `beforeSwap`
    /// with `ReentrantSwap`, and the buy that paid it still completes.
    function test_recipientReenteringAnySwapShapeIsRefusedWithReentrantSwap() public {
        ReenteringRecipient r = new ReenteringRecipient(IPoolManager(address(manager)));
        (BMCHook h, PoolKey memory k) = openPoolWith(address(r), 100, 100);
        r.setKey(k);
        bytes32 expected =
            keccak256(wrapped(h, IHooks.beforeSwap.selector, abi.encodeWithSelector(BMCHook.ReentrantSwap.selector)));

        for (uint8 mode = 0; mode < 4; mode++) {
            r.setMode(mode);
            uint256 before = address(r).balance;
            vm.prank(trader);
            router.buyExactIn{value: 0.1 ether}(k, 1);
            assertEq(address(r).balance - before, 0.001 ether, "the fee was still paid");
            assertEq(r.lastRevert(), expected, "the re-entered swap failed with ReentrantSwap");
        }
        assertEq(h.pendingEthFees(), 0);
        assertEq(h.totalEthFeesPaid(), 0.004 ether);
    }

    /// @dev The guard is per payment: once the recipient has been paid, swapping is open again, and a
    /// recipient that recorded a refusal in no way blocks the next trader.
    function test_swapsResumeAfterARefusedReentry() public {
        ReenteringRecipient r = new ReenteringRecipient(IPoolManager(address(manager)));
        (, PoolKey memory k) = openPoolWith(address(r), 100, 100);
        r.setKey(k);
        vm.startPrank(trader);
        uint256 out = router.buyExactIn{value: 0.1 ether}(k, 1);
        assertTrue(r.lastRevert() != bytes32(0), "the reentry was attempted and refused");
        router.sellExactIn(k, out, 1);
        router.buyExactOut{value: 1 ether}(k, 1_000 ether);
        vm.stopPrank();
    }

    /// @dev The guard also covers the retry path: a recipient re-entering during `collect` is refused.
    function test_recipientReenteringDuringCollectIsRefused() public {
        ReenteringRecipient r = new ReenteringRecipient(IPoolManager(address(manager)));
        (BMCHook h, PoolKey memory k) = openPoolWith(address(r), 100, 100);
        r.setKey(k);
        r.setMode(4); // reject the payment so a claim is left
        vm.prank(trader);
        router.buyExactIn{value: 0.1 ether}(k, 1);
        assertEq(h.pendingEthFees(), 0.001 ether);
        r.setMode(0); // accept again, but try to trade inside the payment
        h.collect();
        assertEq(h.pendingEthFees(), 0);
        assertEq(address(r).balance, 0.001 ether);
        assertEq(
            r.lastRevert(),
            keccak256(wrapped(h, IHooks.beforeSwap.selector, abi.encodeWithSelector(BMCHook.ReentrantSwap.selector)))
        );
    }

    // ------------------------------------------------------------------ the payment gas budget

    /// @dev A recipient that does real work on receipt, well inside the budget, is paid directly.
    function test_recipientUsingMostOfTheBudgetIsStillPaidDirectly() public {
        HeavyWallet w = new HeavyWallet(hook.ETH_PAYOUT_GAS() / 4);
        (BMCHook h, PoolKey memory k) = openPoolWith(address(w), 100, 100);
        vm.prank(trader);
        router.buyExactIn{value: 1 ether}(k, 1);
        assertEq(address(w).balance, 0.01 ether);
        assertEq(h.totalEthFeesPaid(), 0.01 ether);
        assertEq(h.pendingEthFees(), 0);
        assertGt(w.ran(), 0, "the wallet's receive actually ran its work");
    }

    /// @dev A recipient that spins past the budget cannot stall buys: its fee becomes a claim, and the
    /// trader's gas is bounded by the budget rather than exhausted.
    function test_spinningRecipientLeavesAClaimAndDoesNotExhaustTheBuyersGas() public {
        SpinningWallet w = new SpinningWallet();
        (BMCHook h, PoolKey memory k) = openPoolWith(address(w), 100, 100);
        vm.prank(trader);
        uint256 out = router.buyExactIn{value: 1 ether, gas: 600_000}(k, 1);
        assertGt(out, 0);
        assertEq(address(w).balance, 0);
        assertEq(h.pendingEthFees(), 0.01 ether);
        assertEq(h.totalEthFeesPaid(), 0);
        // Collecting spins again and keeps the claim, within a bounded gas budget.
        h.collect{gas: 400_000}();
        assertEq(h.pendingEthFees(), 0.01 ether);
        // Once the wallet stops spinning (here: its code removed, as an EOA), the claim pays out.
        vm.etch(address(w), "");
        h.collect();
        assertEq(address(w).balance, 0.01 ether);
        assertEq(h.pendingEthFees(), 0);
        assertEq(h.totalEthFeesPaid(), 0.01 ether);
    }

    /// @dev Claims that were left by a failing recipient are still backed one-for-one by ETH in the
    /// manager, and later buys that pay directly do not drain them.
    function test_claimsSurviveLaterDirectPaymentsIntact() public {
        SpinningWallet w = new SpinningWallet();
        (BMCHook h, PoolKey memory k) = openPoolWith(address(w), 100, 100);
        vm.startPrank(trader);
        router.buyExactIn{value: 1 ether}(k, 1);
        assertEq(h.pendingEthFees(), 0.01 ether);
        vm.etch(address(w), "");
        router.buyExactIn{value: 1 ether}(k, 1);
        vm.stopPrank();
        assertEq(address(w).balance, 0.01 ether, "the second buy paid directly");
        assertEq(h.pendingEthFees(), 0.01 ether, "the first buy's claim is untouched");
        assertGe(address(manager).balance, h.pendingEthFees());
        h.collect();
        assertEq(address(w).balance, 0.02 ether);
        assertEq(h.totalEthFeesPaid(), 0.02 ether);
    }
}

/// @dev A community wallet that tries to trade on the pool while it is being paid.
contract ReenteringRecipient {
    IPoolManager immutable manager;
    PoolKey key;
    uint8 public mode;
    bytes32 public lastRevert;

    constructor(IPoolManager m) {
        manager = m;
    }

    function setKey(PoolKey memory k) external {
        key = k;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    receive() external payable {
        if (mode == 4) revert("not now");
        SwapParams memory p;
        if (mode == 0) p = SwapParams(true, -int256(1e12), TickMath.MIN_SQRT_PRICE + 1);
        if (mode == 1) p = SwapParams(true, int256(1e12), TickMath.MIN_SQRT_PRICE + 1);
        if (mode == 2) p = SwapParams(false, -int256(1e12), TickMath.MAX_SQRT_PRICE - 1);
        if (mode == 3) p = SwapParams(false, int256(1e9), TickMath.MAX_SQRT_PRICE - 1);
        (bool ok, bytes memory err) = address(manager).call(abi.encodeCall(IPoolManager.swap, (key, p, bytes(""))));
        lastRevert = ok ? bytes32(0) : keccak256(err);
    }
}

/// @dev A wallet whose receive burns a fixed slice of gas, like a smart account doing bookkeeping.
contract HeavyWallet {
    uint256 immutable budget;
    uint256 public ran;

    constructor(uint256 gasToBurn) {
        budget = gasToBurn;
    }

    receive() external payable {
        uint256 start = gasleft();
        uint256 x;
        while (start - gasleft() < budget) {
            x = uint256(keccak256(abi.encode(x)));
        }
        ran++;
    }
}

/// @dev A wallet whose receive never returns on its own: it burns whatever gas it is given.
contract SpinningWallet {
    receive() external payable {
        while (true) {}
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
