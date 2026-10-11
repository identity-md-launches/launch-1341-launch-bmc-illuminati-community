// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BMCSwapRouter} from "../src/BMCSwapRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BMCFixture} from "./utils/BMCFixture.sol";

contract BMCSwapRouterTest is BMCFixture {
    function setUp() public {
        deployCore();
        initializePool();
        addFullRangeLiquidity(1e22, 1.1 ether);
        fundTrader(10 ether, 10_000_000 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function test_buyRevertsBelowMinimumOutput() public {
        vm.prank(trader);
        vm.expectRevert();
        router.buyExactIn{value: 0.1 ether}(key, type(uint256).max);
        assertEq(trader.balance, 10 ether, "nothing was spent");
        assertEq(feeRecipient.balance, 0, "no fee on a reverted swap");
    }

    function test_sellRevertsBelowMinimumOutput() public {
        uint256 supply = token.totalSupply();
        vm.prank(trader);
        vm.expectRevert();
        router.sellExactIn(key, 1_000_000 ether, type(uint256).max);
        assertEq(token.balanceOf(trader), 10_000_000 ether, "tokens were not taken");
        assertEq(token.totalSupply(), supply, "no burn on a reverted swap");
    }

    function test_sellExactOutRevertsWhenMoreTokensAreNeededThanAllowed() public {
        vm.prank(trader);
        vm.expectRevert();
        router.sellExactOut(key, 0.01 ether, 1);
    }

    function test_buyExactOutRevertsWhenEthIsShort() public {
        vm.prank(trader);
        vm.expectRevert();
        router.buyExactOut{value: 1}(key, 1_000_000 ether);
    }

    function test_zeroAmountsRevert() public {
        vm.startPrank(trader);
        vm.expectRevert(BMCSwapRouter.ZeroAmount.selector);
        router.buyExactIn{value: 0}(key, 0);
        vm.expectRevert(BMCSwapRouter.ZeroAmount.selector);
        router.sellExactIn(key, 0, 0);
        vm.stopPrank();
    }

    function test_sellRequiresAllowance() public {
        address other = makeAddr("other");
        token.transfer(other, 1 ether);
        vm.prank(other);
        vm.expectRevert();
        router.sellExactIn(key, 1 ether, 0);
    }

    function test_exactAllowanceIsEnough() public {
        address other = makeAddr("other");
        token.transfer(other, 1_000 ether);
        vm.startPrank(other);
        token.approve(address(router), 1_000 ether);
        router.sellExactIn(key, 1_000 ether, 0);
        vm.stopPrank();
        assertEq(token.balanceOf(other), 0);
        assertEq(token.allowance(other, address(router)), 0);
    }

    function test_routerHoldsNothingAfterSwaps() public {
        vm.startPrank(trader);
        router.buyExactIn{value: 0.3 ether}(key, 0);
        router.buyExactOut{value: 0.3 ether}(key, 100_000 ether);
        router.sellExactIn(key, 100_000 ether, 0);
        router.sellExactOut(key, 0.0001 ether, 1_000_000 ether);
        vm.stopPrank();
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_refusesPoolsNotPairedWithEth() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1 ether);
        PoolKey memory k = key;
        k.currency0 = Currency.wrap(address(other));
        vm.prank(trader);
        vm.expectRevert(BMCSwapRouter.NotEthPool.selector);
        router.buyExactIn{value: 1}(k, 0);
    }

    function test_unlockCallbackRefusesCallersOtherThanThePoolManager() public {
        vm.expectRevert(BMCSwapRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }

    function test_hookOnlyAppliesToItsPool() public view {
        assertEq(address(key.hooks), address(hook));
        assertTrue(IHooks(address(hook)) == key.hooks);
    }
}
