// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BMCHook} from "../src/BMCHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BMCFixture} from "./utils/BMCFixture.sol";

/// @notice The hook on a funded pool: both sides of liquidity, every swap shape.
contract BMCHookTest is BMCFixture {
    uint128 constant LIQUIDITY = 1e22; // about 1 ETH and 100,000,000 BMC at the opening price

    function setUp() public {
        deployCore();
        initializePool();
        addFullRangeLiquidity(LIQUIDITY, 1.1 ether);
        fundTrader(10 ether, 10_000_000 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    // ------------------------------------------------------------------ configuration

    function test_permissionsMatchAddressFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.fromPermissions(p));
        assertEq(HookFlags.fromPermissions(p), hook.HOOK_FLAGS(), "the constant agrees with the permissions");
    }

    function test_immutablesAreTheConstructorArguments() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        assertEq(hook.feeRecipient(), feeRecipient);
        assertEq(hook.buyFeeBps(), BUY_FEE_BPS);
        assertEq(hook.sellBurnBps(), SELL_BURN_BPS);
        assertTrue(hook.poolInitialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(BMCHook.ZeroAddress.selector);
        new BMCHook(IPoolManager(address(0)), address(token), feeRecipient, 100, 100);
        vm.expectRevert(BMCHook.ZeroAddress.selector);
        new BMCHook(IPoolManager(address(manager)), address(0), feeRecipient, 100, 100);
        vm.expectRevert(BMCHook.ZeroAddress.selector);
        new BMCHook(IPoolManager(address(manager)), address(token), address(0), 100, 100);
    }

    function test_constructorRejectsRatesAboveTheCap() public {
        vm.expectRevert(BMCHook.RateTooHigh.selector);
        new BMCHook(IPoolManager(address(manager)), address(token), feeRecipient, 5_001, 100);
        vm.expectRevert(BMCHook.RateTooHigh.selector);
        new BMCHook(IPoolManager(address(manager)), address(token), feeRecipient, 100, 5_001);
    }

    function test_constructorRejectsAnAddressWithoutTheFlags() public {
        // A plain CREATE lands on an address with (almost surely) the wrong bits.
        vm.expectRevert();
        new BMCHook(IPoolManager(address(manager)), address(token), feeRecipient, 100, 100);
    }

    function test_noOwnerOrSetters() public {
        string[6] memory sigs = [
            "owner()",
            "transferOwnership(address)",
            "setFeeRecipient(address)",
            "setBuyFeeBps(uint256)",
            "pause()",
            "withdraw(address,uint256)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], address(this), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(hook.feeRecipient(), feeRecipient);
    }

    // ------------------------------------------------------------------ access control

    function test_everyCallbackRefusesCallersOtherThanThePoolManager() public {
        SwapParams memory sp = SwapParams(true, -1 ether, OPENING_SQRT_PRICE / 2);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = toBalanceDelta(0, 0);
        bytes[11] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), key, OPENING_SQRT_PRICE)),
            abi.encodeCall(IHooks.afterInitialize, (address(this), key, OPENING_SQRT_PRICE, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, lp, "")),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, lp, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeSwap, (address(this), key, sp, "")),
            abi.encodeCall(IHooks.afterSwap, (address(this), key, sp, zero, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(BMCHook.unlockCallback, (""))
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.expectRevert(BMCHook.NotPoolManager.selector);
            (bool ok, bytes memory ret) = address(hook).call(calls[i]);
            ok;
            ret;
        }
    }

    function test_unusedCallbacksRevertEvenForThePoolManager() public {
        vm.prank(address(manager));
        vm.expectRevert(BMCHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, OPENING_SQRT_PRICE, 0);
        vm.prank(address(manager));
        vm.expectRevert(BMCHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
    }

    // ------------------------------------------------------------------ initialization

    function test_initializeFromAnyFactoryAddress() public {
        BMCHook fresh = BMCHook(deployHook(address(manager), address(token), feeRecipient, 100, 100));
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        address factory = makeAddr("launchFactory");
        vm.prank(factory);
        manager.initialize(k, OPENING_SQRT_PRICE);
        assertTrue(fresh.poolInitialized());
    }

    function test_initializeRefusesASecondPool() public {
        PoolKey memory k = key;
        k.fee = 3_000;
        vm.expectRevert();
        manager.initialize(k, OPENING_SQRT_PRICE);
    }

    function test_initializeRefusesAPoolWithoutTheToken() public {
        BMCHook fresh = BMCHook(deployHook(address(manager), address(token), feeRecipient, 100, 100));
        MockERC20 other = new MockERC20("Other", "OTHER", 1 ether);
        PoolKey memory k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(other)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(fresh))
        });
        vm.expectRevert();
        manager.initialize(k, OPENING_SQRT_PRICE);
        assertFalse(fresh.poolInitialized());
    }

    function test_initializeRefusesANonEthPair() public {
        BMCHook fresh = BMCHook(deployHook(address(manager), address(token), feeRecipient, 100, 100));
        MockERC20 other = new MockERC20("Other", "OTHER", 1 ether);
        (address c0, address c1) =
            address(other) < address(token) ? (address(other), address(token)) : (address(token), address(other));
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(fresh))
        });
        vm.expectRevert();
        manager.initialize(k, OPENING_SQRT_PRICE);
    }

    // ------------------------------------------------------------------ buys

    function test_buyExactInput_sendsOnePercentOfEthToTheCommunityWallet() public {
        uint256 ethIn = 0.1 ether;
        uint256 managerBefore = address(manager).balance;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(trader);
        uint256 out = router.buyExactIn{value: ethIn}(key, 0);

        assertGt(out, 0);
        assertEq(token.balanceOf(trader), 10_000_000 ether + out, "trader received the tokens");
        assertEq(feeRecipient.balance, ethIn / 100, "1% of the ETH went to the community wallet as ETH");
        assertEq(address(manager).balance, managerBefore + ethIn - ethIn / 100, "the pool got the other 99%");
        assertEq(address(hook).balance, 0, "the hook keeps no ETH");
        assertEq(hook.pendingEthFees(), 0, "nothing left as a claim");
        assertEq(hook.totalEthFeesPaid(), ethIn / 100);
        assertEq(token.totalSupply(), supplyBefore, "buys burn nothing");
        assertEq(trader.balance, 10 ether - ethIn, "the trader paid exactly what was sent");
    }

    function test_buyExactOutput_feeIsOnePercentOfTotalEthPaid() public {
        uint256 tokensOut = 1_000_000 ether;
        uint256 managerBefore = address(manager).balance;

        vm.prank(trader);
        uint256 ethIn = router.buyExactOut{value: 1 ether}(key, tokensOut);

        uint256 fee = feeRecipient.balance;
        uint256 poolEth = address(manager).balance - managerBefore;
        assertGt(fee, 0);
        assertEq(ethIn, poolEth + fee, "the swapper paid the pool's price plus the fee");
        assertEq(fee, ethIn / 100, "the fee is 1% of the total ETH input");
        assertEq(fee, poolEth * BUY_FEE_BPS / (10_000 - BUY_FEE_BPS), "grossed up from the pool input");
        assertEq(token.balanceOf(trader), 10_000_000 ether + tokensOut, "exactly the requested tokens");
        assertEq(trader.balance, 10 ether - ethIn, "unused ETH was refunded");
        assertEq(hook.pendingEthFees(), 0);
    }

    function testFuzz_buyExactInput_feeIsExactlyOnePercent(uint256 ethIn) public {
        ethIn = bound(ethIn, 1e9, 5 ether);
        vm.prank(trader);
        router.buyExactIn{value: ethIn}(key, 0);
        assertEq(feeRecipient.balance, (ethIn * BUY_FEE_BPS) / 10_000);
        assertEq(hook.pendingEthFees(), 0);
    }

    // ------------------------------------------------------------------ sells

    function test_sellExactInput_burnsOnePercentOfTheTokensSold() public {
        uint256 tokensIn = 1_000_000 ether;
        uint256 supplyBefore = token.totalSupply();
        uint256 managerTokensBefore = token.balanceOf(address(manager));
        uint256 recipientBefore = feeRecipient.balance;

        vm.prank(trader);
        uint256 ethOut = router.sellExactIn(key, tokensIn, 0);

        assertGt(ethOut, 0);
        assertEq(trader.balance, 10 ether + ethOut, "trader received the ETH");
        assertEq(token.totalSupply(), supplyBefore - tokensIn / 100, "1% of the sale was burned from supply");
        assertEq(token.balanceOf(address(manager)), managerTokensBefore + tokensIn - tokensIn / 100, "pool got 99%");
        assertEq(token.balanceOf(address(hook)), 0, "the hook keeps no tokens");
        assertEq(token.balanceOf(address(0)), 0, "burned, not parked at the zero address");
        assertEq(hook.pendingBurns(), 0);
        assertEq(hook.totalTokensBurned(), tokensIn / 100);
        assertEq(feeRecipient.balance, recipientBefore, "sells pay no ETH fee");
        assertEq(token.balanceOf(trader), 10_000_000 ether - tokensIn);
    }

    function test_sellExactOutput_burnsOnePercentOfTotalTokensPaid() public {
        uint256 ethOut = 0.001 ether;
        uint256 supplyBefore = token.totalSupply();
        uint256 managerTokensBefore = token.balanceOf(address(manager));

        vm.prank(trader);
        uint256 tokensIn = router.sellExactOut(key, ethOut, 5_000_000 ether);

        uint256 burned = supplyBefore - token.totalSupply();
        uint256 poolTokens = token.balanceOf(address(manager)) - managerTokensBefore;
        assertGt(burned, 0);
        assertEq(tokensIn, poolTokens + burned, "the seller paid the pool's amount plus the burn");
        assertEq(burned, tokensIn / 100, "the burn is 1% of the total tokens sold");
        assertEq(burned, poolTokens * SELL_BURN_BPS / (10_000 - SELL_BURN_BPS), "grossed up from pool input");
        assertEq(trader.balance, 10 ether + ethOut, "exactly the requested ETH");
        assertEq(token.balanceOf(trader), 10_000_000 ether - tokensIn, "unused tokens were refunded");
        assertEq(hook.pendingBurns(), 0);
    }

    function testFuzz_sellExactInput_burnIsExactlyOnePercent(uint256 tokensIn) public {
        tokensIn = bound(tokensIn, 1e6, 10_000_000 ether);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(trader);
        router.sellExactIn(key, tokensIn, 0);
        assertEq(supplyBefore - token.totalSupply(), (tokensIn * SELL_BURN_BPS) / 10_000);
    }

    function test_roundTripReducesSupplyAndPaysTheWallet() public {
        uint256 supplyBefore = token.totalSupply();
        vm.startPrank(trader);
        uint256 bought = router.buyExactIn{value: 1 ether}(key, 0);
        router.sellExactIn(key, bought, 0);
        vm.stopPrank();
        assertEq(feeRecipient.balance, 0.01 ether);
        assertEq(token.totalSupply(), supplyBefore - bought / 100);
    }

    function test_collectWithNothingPendingChangesNothing() public {
        uint256 supplyBefore = token.totalSupply();
        hook.collect();
        assertEq(feeRecipient.balance, 0);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_hookDoesNotBlockLiquidityChanges() public {
        token.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 1 ether);
        lpRouter.modifyLiquidity{value: 0.5 ether}(
            key, ModifyLiquidityParams(MIN_USABLE_TICK, MAX_USABLE_TICK, int256(1e21), bytes32(uint256(1))), ""
        );
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(MIN_USABLE_TICK, MAX_USABLE_TICK, -int256(1e21), bytes32(uint256(1))), ""
        );
    }
}

/// @notice The hook on a freshly deployed PoolManager whose pool was seeded with tokens only, as the
/// launch seeds it: the manager holds no ETH when the first buy's fee is due.
contract BMCHookTokenOnlyPoolTest is BMCFixture {
    function setUp() public {
        deployCore();
        initializePool();
        addTokenOnlyLiquidity(1e22);
        fundTrader(10 ether, 0);
    }

    function test_firstBuyBooksTheFeeAsAClaim_collectPaysIt() public {
        assertEq(address(manager).balance, 0, "no ETH in the manager before the first buy");
        uint256 ethIn = 0.1 ether;

        vm.prank(trader);
        uint256 out = router.buyExactIn{value: ethIn}(key, 0);

        assertGt(out, 0, "the trade itself went through");
        assertEq(feeRecipient.balance, 0, "nothing could be sent yet");
        assertEq(hook.pendingEthFees(), ethIn / 100, "the fee is held as an ETH claim");
        assertEq(address(manager).balance, ethIn, "the manager now holds the whole input");

        hook.collect();

        assertEq(feeRecipient.balance, ethIn / 100, "collect paid the claim out as ETH");
        assertEq(hook.pendingEthFees(), 0);
        assertEq(hook.totalEthFeesPaid(), ethIn / 100);
    }

    function test_firstExactOutputBuyBooksTheFeeAsAClaim() public {
        vm.prank(trader);
        uint256 ethIn = router.buyExactOut{value: 1 ether}(key, 1_000_000 ether);
        uint256 pending = hook.pendingEthFees();
        assertGt(pending, 0);
        assertEq(pending, ethIn / 100);
        hook.collect();
        assertEq(feeRecipient.balance, pending);
    }

    function test_anyoneCanCollect() public {
        vm.prank(trader);
        router.buyExactIn{value: 1 ether}(key, 0);
        vm.prank(makeAddr("stranger"));
        hook.collect();
        assertEq(feeRecipient.balance, 0.01 ether);
    }

    function test_onceTheManagerHoldsEthLaterBuysPayDirectly() public {
        vm.prank(trader);
        router.buyExactIn{value: 1 ether}(key, 0);
        assertEq(hook.pendingEthFees(), 0.01 ether);

        vm.prank(trader);
        router.buyExactIn{value: 0.5 ether}(key, 0);
        assertEq(feeRecipient.balance, 0.005 ether, "the second buy's fee went straight out");
        assertEq(hook.pendingEthFees(), 0.01 ether, "the first claim is still pending");

        hook.collect();
        assertEq(feeRecipient.balance, 0.015 ether);
    }

    function test_largeFullyFilledBuyPaysOnePercent() public {
        // This full-range position has enough BMC to fill even this large input.
        vm.deal(trader, 100 ether);
        vm.prank(trader);
        uint256 out = router.buyExactIn{value: 100 ether}(key, 0);
        assertGt(out, 0);
        assertEq(hook.pendingEthFees(), 1 ether, "1% of the specified input, booked before the fill");
        assertEq(address(manager).balance, 100 ether, "the manager holds the input, fee included");
    }
}

/// @notice The hook on a pool seeded with ETH only: the manager holds no BMC when the first sale's burn is due.
contract BMCHookEthOnlyPoolTest is BMCFixture {
    function setUp() public {
        deployCore();
        initializePool();
        addEthOnlyLiquidity(1e22, 1.1 ether);
        fundTrader(0, 10_000_000 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function test_firstSaleBooksTheBurnAsAClaim_collectBurnsIt() public {
        assertEq(token.balanceOf(address(manager)), 0, "no BMC in the manager before the first sale");
        uint256 tokensIn = 1_000_000 ether;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(trader);
        uint256 ethOut = router.sellExactIn(key, tokensIn, 0);

        assertGt(ethOut, 0, "the trade itself went through");
        assertEq(token.totalSupply(), supplyBefore, "nothing could be burned yet");
        assertEq(hook.pendingBurns(), tokensIn / 100, "the burn is held as a BMC claim");

        hook.collect();

        assertEq(token.totalSupply(), supplyBefore - tokensIn / 100, "collect burned the claim");
        assertEq(hook.pendingBurns(), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(hook.totalTokensBurned(), tokensIn / 100);
    }

    function test_firstExactOutputSaleBooksTheBurnAsAClaim() public {
        uint256 supplyBefore = token.totalSupply();
        vm.prank(trader);
        uint256 tokensIn = router.sellExactOut(key, 0.001 ether, 5_000_000 ether);
        uint256 pending = hook.pendingBurns();
        assertGt(pending, 0);
        assertEq(pending, tokensIn / 100);
        hook.collect();
        assertEq(token.totalSupply(), supplyBefore - pending);
    }
}
