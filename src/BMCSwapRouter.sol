// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title BMCSwapRouter
/// @notice A minimal, ownerless router for swapping ETH against an ERC-20 on a Uniswap v4 pool whose
/// currency0 is native ETH. The website uses it so a wallet can approve an exact amount and then
/// buy or sell without Permit2 or the Universal Router.
/// @dev The caller's tokens are pulled with `transferFrom(msg.sender, ...)` in the entry point, and the
/// swap is settled from the router's own balance in `unlockCallback`, which only the PoolManager may
/// call. Whatever the swap did not use is refunded to the caller in the same transaction. The router
/// keeps no state and holds nothing between transactions.
contract BMCSwapRouter is IUnlockCallback {
    IPoolManager public immutable poolManager;

    struct CallbackData {
        address payer;
        PoolKey key;
        SwapParams params;
    }

    event Swapped(address indexed trader, bool indexed buy, uint256 ethAmount, uint256 tokenAmount);

    error NotPoolManager();
    error NotEthPool();
    error TooLittleReceived(uint256 received, uint256 minimum);
    error TooMuchRequested(uint256 required, uint256 maximum);
    error ZeroAmount();
    error EthTransferFailed();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    receive() external payable {}

    /// @notice Buy tokens with exactly `msg.value` ETH; revert unless at least `minTokensOut` come back.
    function buyExactIn(PoolKey calldata key, uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        _requireEthPool(key);
        if (msg.value == 0) revert ZeroAmount();
        BalanceDelta delta = _swap(key, true, -int256(msg.value));
        tokensOut = uint256(uint128(delta.amount1()));
        if (tokensOut < minTokensOut) revert TooLittleReceived(tokensOut, minTokensOut);
        _refundEth();
        emit Swapped(msg.sender, true, msg.value, tokensOut);
    }

    /// @notice Buy exactly `tokensOut` tokens, paying at most `msg.value` ETH; the rest is refunded.
    function buyExactOut(PoolKey calldata key, uint256 tokensOut) external payable returns (uint256 ethIn) {
        _requireEthPool(key);
        if (tokensOut == 0) revert ZeroAmount();
        BalanceDelta delta = _swap(key, true, int256(tokensOut));
        ethIn = uint256(uint128(-delta.amount0()));
        _refundEth();
        emit Swapped(msg.sender, true, ethIn, tokensOut);
    }

    /// @notice Sell exactly `tokensIn` tokens (approved to this router) for at least `minEthOut` ETH.
    function sellExactIn(PoolKey calldata key, uint256 tokensIn, uint256 minEthOut) external returns (uint256 ethOut) {
        _requireEthPool(key);
        if (tokensIn == 0) revert ZeroAmount();
        IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), tokensIn);
        BalanceDelta delta = _swap(key, false, -int256(tokensIn));
        ethOut = uint256(uint128(delta.amount0()));
        if (ethOut < minEthOut) revert TooLittleReceived(ethOut, minEthOut);
        _refundTokens(key.currency1);
        emit Swapped(msg.sender, false, ethOut, tokensIn);
    }

    /// @notice Receive exactly `ethOut` ETH, selling at most `maxTokensIn` tokens (approved to this router).
    function sellExactOut(PoolKey calldata key, uint256 ethOut, uint256 maxTokensIn)
        external
        returns (uint256 tokensIn)
    {
        _requireEthPool(key);
        if (ethOut == 0 || maxTokensIn == 0) revert ZeroAmount();
        IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), maxTokensIn);
        BalanceDelta delta = _swap(key, false, int256(ethOut));
        tokensIn = uint256(uint128(-delta.amount1()));
        if (tokensIn > maxTokensIn) revert TooMuchRequested(tokensIn, maxTokensIn);
        _refundTokens(key.currency1);
        emit Swapped(msg.sender, false, ethOut, tokensIn);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.swap(data.key, data.params, "");
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) {
            poolManager.settle{value: uint256(uint128(-amount0))}();
        } else if (amount0 > 0) {
            poolManager.take(data.key.currency0, data.payer, uint256(uint128(amount0)));
        }

        if (amount1 < 0) {
            uint256 owed = uint256(uint128(-amount1));
            poolManager.sync(data.key.currency1);
            data.key.currency1.transfer(address(poolManager), owed);
            poolManager.settle();
        } else if (amount1 > 0) {
            poolManager.take(data.key.currency1, data.payer, uint256(uint128(amount1)));
        }

        return abi.encode(delta);
    }

    function _swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory result =
            poolManager.unlock(abi.encode(CallbackData({payer: msg.sender, key: key, params: params})));
        return abi.decode(result, (BalanceDelta));
    }

    function _requireEthPool(PoolKey calldata key) internal pure {
        if (!key.currency0.isAddressZero()) revert NotEthPool();
    }

    function _refundEth() internal {
        uint256 left = address(this).balance;
        if (left > 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    function _refundTokens(Currency currency) internal {
        uint256 left = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (left > 0) currency.transfer(msg.sender, left);
    }
}
