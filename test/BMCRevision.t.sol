// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BMCFixture} from "./utils/BMCFixture.sol";
import {BMCHook, BMC_HOOK_FLAGS} from "../src/BMCHook.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Regression cases for partial fills, including the launch's BMC-only initial position.
contract BMCPartialFillTest is BMCFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        deployCore();
        initializePool();
        fundTrader(10 ether, 100_000_000 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function stateHash() internal view returns (bytes32) {
        (uint160 price, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                trader.balance,
                token.balanceOf(trader),
                token.totalSupply(),
                address(manager).balance,
                token.balanceOf(address(manager)),
                feeRecipient.balance,
                hook.totalEthFeesPaid(),
                hook.totalTokensBurned(),
                hook.pendingEthFees(),
                hook.pendingBurns(),
                address(router).balance,
                token.balanceOf(address(router)),
                token.allowance(trader, address(router))
            )
        );
    }

    function seedThinPosition() internal {
        token.approve(address(lpRouter), type(uint256).max);
        int24 upper = (openingTick() / TICK_SPACING) * TICK_SPACING;
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(upper - 60, upper, 1e22, 0), "");
    }

    function test_zeroFillSaleRevertsWithoutBurningOrMovingThePrice() public {
        addTokenOnlyLiquidity(1e22);
        bytes32 beforeState = stateHash();
        vm.prank(trader);
        vm.expectRevert();
        router.sellExactIn(key, 1_000_000 ether, 0);
        assertEq(stateHash(), beforeState);
    }

    function test_saleBeyondAvailableEthRevertsWithoutBurning() public {
        addTokenOnlyLiquidity(1e22);
        vm.prank(trader);
        router.buyExactIn{value: 0.1 ether}(key, 0);
        bytes32 beforeState = stateHash();
        vm.prank(trader);
        vm.expectRevert();
        router.sellExactIn(key, 100_000_000 ether, 0);
        assertEq(stateHash(), beforeState);
    }

    function test_buyAtTightPriceLimitRollsBackThePrepaidEthFee() public {
        addFullRangeLiquidity(1e22, 1.1 ether);
        PoolSwapTest otherRouter = new PoolSwapTest(IPoolManager(address(manager)));
        bytes32 beforeState = stateHash();
        vm.prank(trader);
        vm.expectRevert();
        otherRouter.swap{value: 1 ether}(
            key,
            SwapParams(true, -1 ether, OPENING_SQRT_PRICE * 999 / 1000),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(stateHash(), beforeState);
    }

    function test_saleAtTightPriceLimitRollsBackThePrepaidBurn() public {
        addFullRangeLiquidity(1e22, 1.1 ether);
        PoolSwapTest otherRouter = new PoolSwapTest(IPoolManager(address(manager)));
        vm.prank(trader);
        token.approve(address(otherRouter), 10_000_000 ether);
        bytes32 beforeState = stateHash();
        vm.prank(trader);
        vm.expectRevert();
        otherRouter.swap(
            key,
            SwapParams(false, -int256(10_000_000 ether), OPENING_SQRT_PRICE * 1001 / 1000),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(stateHash(), beforeState);
    }

    function test_buyBeyondTokenLiquidityRollsBackTheFeeClaim() public {
        seedThinPosition();
        bytes32 beforeState = stateHash();
        vm.prank(trader);
        vm.expectRevert();
        router.buyExactIn{value: 1 ether}(key, 0);
        assertEq(stateHash(), beforeState);
    }

    function test_exactOutputSaleWithNoEthReverts() public {
        addTokenOnlyLiquidity(1e22);
        bytes32 beforeState = stateHash();
        vm.prank(trader);
        vm.expectRevert();
        router.sellExactOut(key, 0.01 ether, 10_000_000 ether);
        assertEq(stateHash(), beforeState);
    }

    function test_exactOutputSaleBeyondLiquidityReverts() public {
        addTokenOnlyLiquidity(1e22);
        vm.prank(trader);
        router.buyExactIn{value: 0.1 ether}(key, 0);
        bytes32 beforeState = stateHash();
        vm.prank(trader);
        vm.expectRevert();
        router.sellExactOut(key, 1 ether, 100_000_000 ether);
        assertEq(stateHash(), beforeState);
    }

    function test_exactOutputBuyBeyondLiquidityReverts() public {
        seedThinPosition();
        bytes32 beforeState = stateHash();
        vm.prank(trader);
        vm.expectRevert();
        router.buyExactOut{value: 1 ether}(key, 1_000_000 ether);
        assertEq(stateHash(), beforeState);
    }

    function test_successfulLaunchBuyThenSaleStillFills() public {
        addTokenOnlyLiquidity(1e22);
        vm.startPrank(trader);
        uint256 bought = router.buyExactIn{value: 0.1 ether}(key, 1);
        uint256 ethOut = router.sellExactIn(key, bought, 1);
        vm.stopPrank();
        assertGt(ethOut, 0);
        assertEq(hook.totalTokensBurned(), bought / 100);
        assertEq(hook.pendingEthFees(), 0.001 ether);
    }
}

contract RevertingFeeRecipient {
    receive() external payable {
        revert("reject ETH");
    }
}

contract GasExhaustingFeeRecipient {
    receive() external payable {
        assembly { invalid() }
    }
}

contract ReenteringFeeRecipient {
    IPoolManager private immutable manager;
    PoolKey private key;
    bool public attempted;
    bool public traded;

    constructor(IPoolManager pm, PoolKey memory k) {
        manager = pm;
        key = k;
    }

    receive() external payable {
        attempted = true;
        // Calls the manager directly while it is unlocked; no new unlock is needed.
        (traded,) = address(manager)
            .call(
                abi.encodeCall(
                    IPoolManager.swap, (key, SwapParams(true, -int256(1e12), (uint160(10_000) << 96) / 2), bytes(""))
                )
            );
    }
}

contract BMCRecipientFailureTest is BMCFixture {
    function setUp() public {
        deployCore();
        initializePool();
        addFullRangeLiquidity(1e22, 1.1 ether);
        fundTrader(10 ether, 10_000_000 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function rejectEth() internal {
        vm.etch(feeRecipient, address(new RevertingFeeRecipient()).code);
    }

    function test_rejectedBuyFeeBecomesAClaimAndLaterPaysExactlyOnce() public {
        rejectEth();
        uint256 managerBefore = address(manager).balance;
        vm.prank(trader);
        assertGt(router.buyExactIn{value: 0.1 ether}(key, 1), 0);
        assertEq(hook.pendingEthFees(), 0.001 ether);
        assertEq(hook.totalEthFeesPaid(), 0);
        assertEq(address(manager).balance, managerBefore + 0.1 ether);
        hook.collect();
        hook.collect();
        assertEq(hook.pendingEthFees(), 0.001 ether, "failed collection retains the entire claim");
        assertEq(hook.totalEthFeesPaid(), 0);
        assertEq(feeRecipient.balance, 0);
        vm.etch(feeRecipient, "");
        hook.collect();
        assertEq(hook.pendingEthFees(), 0);
        assertEq(hook.totalEthFeesPaid(), 0.001 ether);
        assertEq(feeRecipient.balance, 0.001 ether);
        hook.collect();
        assertEq(feeRecipient.balance, 0.001 ether, "cannot pay twice");
    }

    function test_exactOutputBuyRetainsRejectedFeeAndSellsStillWork() public {
        rejectEth();
        vm.startPrank(trader);
        uint256 paid = router.buyExactOut{value: 1 ether}(key, 1_000_000 ether);
        assertEq(hook.pendingEthFees(), paid / 100);
        uint256 supply = token.totalSupply();
        assertGt(router.sellExactIn(key, 1_000_000 ether, 1), 0);
        vm.stopPrank();
        assertEq(token.totalSupply(), supply - 10_000 ether);
        assertEq(hook.pendingEthFees(), paid / 100);
        assertEq(hook.totalEthFeesPaid(), 0);
    }

    function test_gasExhaustingRecipientCannotHaltBuyOrCollection() public {
        vm.etch(feeRecipient, address(new GasExhaustingFeeRecipient()).code);
        vm.prank(trader);
        assertGt(router.buyExactIn{value: 0.1 ether, gas: 700_000}(key, 1), 0);
        hook.collect{gas: 400_000}();
        assertEq(hook.pendingEthFees(), 0.001 ether);
        assertEq(hook.totalEthFeesPaid(), 0);
    }

    function test_recipientCannotTradeAheadInsideTheBuyFeePayment() public {
        ReenteringFeeRecipient receiver = new ReenteringFeeRecipient(IPoolManager(address(manager)), key);
        vm.etch(feeRecipient, address(receiver).code);
        // PoolKey lives in storage; copy the test receiver's key into the delegated address.
        for (uint256 i = 0; i < 3; i++) {
            vm.store(feeRecipient, bytes32(i), vm.load(address(receiver), bytes32(i)));
        }
        vm.prank(trader);
        assertGt(router.buyExactIn{value: 0.1 ether}(key, 1), 0);
        assertTrue(ReenteringFeeRecipient(payable(feeRecipient)).attempted());
        assertFalse(ReenteringFeeRecipient(payable(feeRecipient)).traded());
        assertEq(feeRecipient.balance, 0.001 ether);
        assertEq(hook.pendingEthFees(), 0);
    }

    function testFuzz_exactOutputBuyChargesOnePercentOfTotal(uint256 tokensOut) public {
        tokensOut = bound(tokensOut, 1e6, 10_000_000 ether);
        vm.prank(trader);
        uint256 paid = router.buyExactOut{value: 1 ether}(key, tokensOut);
        assertEq(feeRecipient.balance, paid / 100);
        assertEq(hook.totalEthFeesPaid(), paid / 100);
        assertEq(hook.pendingEthFees(), 0);
    }

    function testFuzz_exactOutputSellBurnsOnePercentOfTotal(uint256 ethOut) public {
        ethOut = bound(ethOut, 1e6, 0.05 ether);
        uint256 supply = token.totalSupply();
        vm.prank(trader);
        uint256 paid = router.sellExactOut(key, ethOut, 10_000_000 ether);
        assertEq(supply - token.totalSupply(), paid / 100);
        assertEq(hook.totalTokensBurned(), paid / 100);
        assertEq(hook.pendingBurns(), 0);
    }
}

contract BMCCollectionFailureTest is BMCFixture {
    function test_rejectedEthCollectionStillProcessesPendingBurns() public {
        deployCore();
        initializePool();
        addEthOnlyLiquidity(1e22, 1.1 ether);
        fundTrader(1 ether, 10_000_000 ether);
        vm.etch(feeRecipient, address(new RevertingFeeRecipient()).code);
        vm.startPrank(trader);
        token.approve(address(router), 1_000_000 ether);
        router.sellExactIn(key, 1_000_000 ether, 1);
        router.buyExactIn{value: 0.0001 ether}(key, 1);
        vm.stopPrank();
        assertEq(hook.pendingBurns(), 10_000 ether);
        assertEq(hook.pendingEthFees(), 0.000001 ether);
        uint256 supply = token.totalSupply();
        hook.collect();
        assertEq(hook.pendingBurns(), 0);
        assertEq(token.totalSupply(), supply - 10_000 ether);
        assertEq(hook.pendingEthFees(), 0.000001 ether);
        assertEq(hook.totalEthFeesPaid(), 0);
        assertEq(feeRecipient.balance, 0);
    }
}

/// @notice The required initialization callback prevents front-running the undeployed hook address.
contract BMCAtomicInitializationTest is BMCFixture {
    function test_predictedPoolCannotInitializeBeforeHookDeployment() public {
        deployCore();
        bytes memory code = abi.encodePacked(
            type(BMCHook).creationCode,
            abi.encode(address(manager), address(token), feeRecipient, uint256(100), uint256(100))
        );
        (bytes32 salt, address predicted) = HookDeployer.mine(address(this), code, BMC_HOOK_FLAGS, 500_000);
        PoolKey memory k = key;
        k.hooks = IHooks(predicted);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        manager.initialize(k, OPENING_SQRT_PRICE);
        // The factory deploys and initializes in this single transaction, leaving no public window.
        BMCHook deployed =
            new BMCHook{salt: salt}(IPoolManager(address(manager)), address(token), feeRecipient, 100, 100);
        assertEq(address(deployed), predicted);
        manager.initialize(k, OPENING_SQRT_PRICE);
        assertTrue(BMCHook(predicted).poolInitialized());
    }
}
