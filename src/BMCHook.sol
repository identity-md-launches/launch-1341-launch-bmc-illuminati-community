// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

// The address bits BMCHook must be deployed under: beforeInitialize, beforeSwap, afterSwap and both
// swap return deltas.
uint160 constant BMC_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

/// @notice The one non-ERC-20 call the hook makes on the launch token.
interface IBurnableToken {
    function burn(uint256 amount) external;
}

/// @title BMCHook
/// @notice The Uniswap v4 hook attached to the BMC Illuminati / ETH pool.
/// @dev On every swap in its pool:
///  - Buy (ETH in, BMC out): an extra `buyFeeBps` of the ETH side is taken and sent, as ETH, to
///    `feeRecipient` (the community wallet) inside the swap that paid it.
///  - Sell (BMC in, ETH out): `sellBurnBps` of the BMC being sold is taken and burned, which permanently
///    reduces the token's total supply.
/// Exact-input swaps are charged in `beforeSwap` (the fee comes off the specified input, and the pool
/// swaps the rest); exact-output swaps are charged in `afterSwap` (the fee is added to the unspecified
/// input). Exact-input swaps must fill the entire input less the fee, or revert atomically. Both swap
/// shapes charge the rate on the total input, including the hook fee. ETH payments that cannot be
/// delivered become ERC-6909 claims that anyone can retry with `collect`.
///
/// Nobody can change anything: every rate and the recipient are immutable constructor arguments. There
/// is no owner, no pause and no other fee.
contract BMCHook is IHooks, IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Hooks for IHooks;

    /// @notice Basis-point denominator: 10_000 = 100%.
    uint256 public constant BPS = 10_000;
    /// @notice The highest rate accepted at construction, 50%. The launch uses 1% for both.
    uint256 public constant MAX_RATE_BPS = 5_000;
    /// @notice The address bits this hook must be deployed under; equals `getHookPermissions()`.
    uint160 public constant HOOK_FLAGS = BMC_HOOK_FLAGS;
    /// @notice Bounded payment attempt; a recipient exhausting this gas leaves a claim instead.
    uint256 public constant ETH_PAYOUT_GAS = 100_000;

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The launch token (BMC). Its pool pairs it with native ETH.
    address public immutable token;
    /// @notice Where the ETH buy fee goes: the community wallet.
    address public immutable feeRecipient;
    /// @notice Fee on buys, as basis points of the ETH side of the trade.
    uint256 public immutable buyFeeBps;
    /// @notice Share of every sale's BMC that is burned, in basis points.
    uint256 public immutable sellBurnBps;

    /// @notice The id of the one pool this hook is attached to; zero until the launch opens it.
    PoolId public poolId;
    bool public poolInitialized;

    /// @notice Total ETH the buy fee has sent to `feeRecipient`, directly or through `collect`.
    uint256 public totalEthFeesPaid;
    /// @notice Total BMC burned by the sell rule.
    uint256 public totalTokensBurned;
    bool private payingEth;

    event PoolAttached(PoolId indexed id, Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing);
    event BuyFeeTaken(uint256 amount, bool paidDirectly);
    event SellBurn(uint256 amount, bool burnedDirectly);
    event FeesCollected(uint256 ethPaid, uint256 tokensBurned);

    error NotPoolManager();
    error ZeroAddress();
    error RateTooHigh();
    error WrongPoolCurrencies();
    error AlreadyInitialized();
    error HookNotImplemented();
    error PartialFill(uint256 expectedInput, uint256 consumedInput);
    error ReentrantSwap();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The chain's Uniswap v4 PoolManager (manifest: "$poolManager").
    /// @param _token The launch token (manifest: "$token").
    /// @param _feeRecipient The community wallet that receives the ETH buy fee.
    /// @param _buyFeeBps Buy fee in basis points of the ETH side (100 = 1%).
    /// @param _sellBurnBps Share of sold BMC burned, in basis points (100 = 1%).
    constructor(
        IPoolManager _poolManager,
        address _token,
        address _feeRecipient,
        uint256 _buyFeeBps,
        uint256 _sellBurnBps
    ) {
        if (address(_poolManager) == address(0) || _token == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        if (_buyFeeBps > MAX_RATE_BPS || _sellBurnBps > MAX_RATE_BPS) revert RateTooHigh();
        poolManager = _poolManager;
        token = _token;
        feeRecipient = _feeRecipient;
        buyFeeBps = _buyFeeBps;
        sellBurnBps = _sellBurnBps;
        // Pure check of this contract's own address bits; no external call.
        IHooks(address(this)).validateHookPermissions(getHookPermissions());
    }

    // ------------------------------------------------------------------
    // Permissions
    // ------------------------------------------------------------------

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Accepts exactly one pool: native ETH against the launch token, at any listed LP fee and
    /// tick spacing. Attaching it to a second pool, or to any other pair, is refused.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (poolInitialized) revert AlreadyInitialized();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != token) revert WrongPoolCurrencies();
        poolInitialized = true;
        poolId = key.toId();
        emit PoolAttached(poolId, key.currency0, key.currency1, key.fee, key.tickSpacing);
        return IHooks.beforeInitialize.selector;
    }

    // ------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Exact-input swaps pay here: the fee is taken off the specified input and the pool swaps the
    /// remainder. Exact-output swaps pass through untouched and pay in `afterSwap`.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (payingEth) revert ReentrantSwap();
        if (params.amountSpecified >= 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 fee;
        if (params.zeroForOne) {
            // Buy: ETH is the specified input.
            fee = (amountIn * buyFeeBps) / BPS;
            if (fee > 0) _takeEthFee(fee);
        } else {
            // Sell: BMC is the specified input.
            fee = (amountIn * sellBurnBps) / BPS;
            if (fee > 0) _takeAndBurn(fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Refuses exact-input short fills so the precharged fee never exceeds the agreed share.
    /// Exact-output fees are grossed up from the pool's input to the same share of total input.
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (params.amountSpecified < 0) {
            uint256 amountIn = uint256(-params.amountSpecified);
            uint256 rate = params.zeroForOne ? buyFeeBps : sellBurnBps;
            uint256 expectedInput = amountIn - (amountIn * rate) / BPS;
            int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
            uint256 consumedInput = inputDelta < 0 ? uint256(-int256(inputDelta)) : 0;
            if (consumedInput != expectedInput) revert PartialFill(expectedInput, consumedInput);
            return (IHooks.afterSwap.selector, 0);
        }
        if (params.amountSpecified == 0) {
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 fee;
        if (params.zeroForOne) {
            // Buy: ETH (currency0) is the unspecified input; the swapper's delta is negative.
            int128 ethDelta = delta.amount0();
            uint256 ethIn = ethDelta < 0 ? uint256(uint128(-ethDelta)) : 0;
            fee = (ethIn * buyFeeBps) / (BPS - buyFeeBps);
            if (fee > 0) _takeEthFee(fee);
        } else {
            // Sell: BMC (currency1) is the unspecified input.
            int128 tokenDelta = delta.amount1();
            uint256 tokenIn = tokenDelta < 0 ? uint256(uint128(-tokenDelta)) : 0;
            fee = (tokenIn * sellBurnBps) / (BPS - sellBurnBps);
            if (fee > 0) _takeAndBurn(fee);
        }
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    // ------------------------------------------------------------------
    // Fee settlement
    // ------------------------------------------------------------------

    /// @dev Sends ETH when possible; insufficient funds or a failed payment leave an ETH claim.
    function _takeEthFee(uint256 fee) internal {
        if (address(poolManager).balance >= fee && _tryPayEth(fee)) {
            totalEthFeesPaid += fee;
            emit BuyFeeTaken(fee, true);
        } else {
            poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fee);
            emit BuyFeeTaken(fee, false);
        }
    }

    /// @dev A reverted `take` rolls back its manager delta too. Bound gas so an uncooperative
    /// delegated wallet cannot exhaust the swap's gas; block trading reentry during the payment.
    function _tryPayEth(uint256 amount) internal returns (bool paid) {
        payingEth = true;
        try poolManager.take{gas: ETH_PAYOUT_GAS}(CurrencyLibrary.ADDRESS_ZERO, feeRecipient, amount) {
            paid = true;
        } catch {}
        payingEth = false;
    }

    /// @dev Pulls `amount` BMC out of the PoolManager and burns it when the manager holds enough,
    /// else books an ERC-6909 BMC claim for the hook that `collect` redeems and burns later.
    function _takeAndBurn(uint256 amount) internal {
        Currency c = Currency.wrap(token);
        if (IERC20Minimal(token).balanceOf(address(poolManager)) >= amount) {
            poolManager.take(c, address(this), amount);
            IBurnableToken(token).burn(amount);
            totalTokensBurned += amount;
            emit SellBurn(amount, true);
        } else {
            poolManager.mint(address(this), c.toId(), amount);
            emit SellBurn(amount, false);
        }
    }

    /// @notice ETH fees booked as claims and not yet paid to the recipient.
    function pendingEthFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), CurrencyLibrary.ADDRESS_ZERO.toId());
    }

    /// @notice BMC booked as claims and not yet burned.
    function pendingBurns() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(token).toId());
    }

    /// @notice Redeems whatever claims the hook holds: pays the ETH to the recipient and burns the BMC.
    /// Anyone may call it; unsuccessful ETH payments retain their claims for a later retry.
    function collect() external {
        poolManager.unlock("");
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata) external override onlyPoolManager returns (bytes memory) {
        uint256 ethPaid = _redeem(CurrencyLibrary.ADDRESS_ZERO, address(poolManager).balance);
        if (ethPaid > 0) {
            if (_tryPayEth(ethPaid)) {
                totalEthFeesPaid += ethPaid;
            } else {
                // Restore the burned claims, cancelling their positive manager delta.
                poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), ethPaid);
                ethPaid = 0;
            }
        }
        Currency c = Currency.wrap(token);
        uint256 burned = _redeem(c, IERC20Minimal(token).balanceOf(address(poolManager)));
        if (burned > 0) {
            poolManager.take(c, address(this), burned);
            IBurnableToken(token).burn(burned);
            totalTokensBurned += burned;
        }
        emit FeesCollected(ethPaid, burned);
        return "";
    }

    /// @dev Burns as many of the hook's claims on `currency` as `available` covers; returns that amount.
    function _redeem(Currency currency, uint256 available) internal returns (uint256 amount) {
        uint256 claims = poolManager.balanceOf(address(this), currency.toId());
        amount = claims < available ? claims : available;
        if (amount > 0) poolManager.burn(address(this), currency.toId(), amount);
    }

    // ------------------------------------------------------------------
    // Callbacks this hook does not enable. They still refuse every caller but the PoolManager and
    // revert even for it, so a mis-set address bit can never silently pass.
    // ------------------------------------------------------------------

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
