// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BMCToken} from "../../src/BMCToken.sol";
import {BMCHook, BMC_HOOK_FLAGS} from "../../src/BMCHook.sol";
import {BMCSwapRouter} from "../../src/BMCSwapRouter.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";

/// @notice Shared setup: a real PoolManager, the token, the hook at a mined address, the router and
/// a liquidity helper. The pool opens where the launch does: 10 ETH for the whole supply.
abstract contract BMCFixture is Test {
    uint24 constant LP_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint256 constant BUY_FEE_BPS = 100;
    uint256 constant SELL_BURN_BPS = 100;
    /// @dev 1e8 BMC per ETH (1e9 BMC = 10 ETH): sqrt(1e8) = 1e4, in Q96.
    uint160 constant OPENING_SQRT_PRICE = uint160(10_000) << 96;
    int24 constant MIN_USABLE_TICK = -887_220;
    int24 constant MAX_USABLE_TICK = 887_220;

    address feeRecipient = makeAddr("communityWallet");
    address trader = makeAddr("trader");

    PoolManager manager;
    BMCToken token;
    BMCHook hook;
    BMCSwapRouter router;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;

    function deployCore() internal {
        manager = new PoolManager(address(this));
        token = new BMCToken();
        router = new BMCSwapRouter(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        hook = BMCHook(deployHook(address(manager), address(token), feeRecipient, BUY_FEE_BPS, SELL_BURN_BPS));
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function deployHook(address pm, address tok, address recipient, uint256 buyBps, uint256 sellBps)
        internal
        returns (address)
    {
        bytes memory creationCode =
            abi.encodePacked(type(BMCHook).creationCode, abi.encode(pm, tok, recipient, buyBps, sellBps));
        uint160 flags = BMC_HOOK_FLAGS;
        return HookDeployer.deploy(creationCode, flags);
    }

    function initializePool() internal {
        manager.initialize(key, OPENING_SQRT_PRICE);
    }

    function openingTick() internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(OPENING_SQRT_PRICE);
    }

    /// @dev Full-range, two-sided liquidity: both ETH and BMC in the pool.
    function addFullRangeLiquidity(uint128 liquidity, uint256 ethBudget) internal {
        token.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), address(this).balance + ethBudget);
        lpRouter.modifyLiquidity{value: ethBudget}(
            key, ModifyLiquidityParams(MIN_USABLE_TICK, MAX_USABLE_TICK, int256(uint256(liquidity)), 0), ""
        );
    }

    /// @dev Tokens-only liquidity below the current price, as the launch seeds its pool: buys sell
    /// into it and no ETH sits in the manager until the first buy settles.
    function addTokenOnlyLiquidity(uint128 liquidity) internal {
        token.approve(address(lpRouter), type(uint256).max);
        int24 upper = (openingTick() / TICK_SPACING) * TICK_SPACING;
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(MIN_USABLE_TICK, upper, int256(uint256(liquidity)), 0), "");
    }

    /// @dev ETH-only liquidity above the current price: sells push into it and no BMC sits in the
    /// manager until the first sale settles.
    function addEthOnlyLiquidity(uint128 liquidity, uint256 ethBudget) internal {
        vm.deal(address(this), address(this).balance + ethBudget);
        int24 lower = ((openingTick() / TICK_SPACING) + 1) * TICK_SPACING;
        lpRouter.modifyLiquidity{value: ethBudget}(
            key, ModifyLiquidityParams(lower, MAX_USABLE_TICK, int256(uint256(liquidity)), 0), ""
        );
    }

    function fundTrader(uint256 eth, uint256 tokens) internal {
        vm.deal(trader, eth);
        if (tokens > 0) token.transfer(trader, tokens);
    }

    receive() external payable {}
}
