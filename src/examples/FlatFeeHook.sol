// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Charges 1% of the actual unspecified swap amount, held as ERC-6909 claims.
/// @dev Only the enabled IHooks callback is implemented. Other selectors revert.
contract FlatFeeHook is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable feeRecipient;

    error ZeroAddress();
    error OnlyPoolManager();
    error DynamicFeeNotSupported();

    event FeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);

    constructor(IPoolManager manager, address recipient) {
        if (address(manager) == address(0) || recipient == address(0)) revert ZeroAddress();
        poolManager = manager;
        feeRecipient = recipient;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (LPFeeLibrary.isDynamicFee(key.fee)) revert DynamicFeeNotSupported();

        // Exact input: charge the output. Exact output: charge the input.
        bool unspecifiedIsCurrency1 = (params.amountSpecified < 0) == params.zeroForOne;
        int256 unspecified = unspecifiedIsCurrency1 ? int256(delta.amount1()) : int256(delta.amount0());
        // Widen before negation so even int128.min is safe.
        uint256 amount = uint256(unspecified < 0 ? -unspecified : unspecified) / 100;
        if (amount != 0) {
            Currency currency = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
            poolManager.mint(address(this), currency.toId(), amount);
        }
        // abs(int128) / 100 always fits in a positive int128.
        return (IHooks.afterSwap.selector, int128(int256(amount)));
    }

    /// @notice Anyone can redeem all claims of a currency to the fixed recipient.
    /// @dev Requires a locked manager; calling during another unlock reverts.
    function collect(Currency currency) external returns (uint256 amount) {
        amount = abi.decode(poolManager.unlock(abi.encode(currency)), (uint256));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        Currency currency = abi.decode(data, (Currency));
        uint256 amount = poolManager.balanceOf(address(this), currency.toId());
        if (amount != 0) {
            // Burn before the external transfer. These two operations net the unlock delta to zero.
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, feeRecipient, amount);
        }
        emit FeesCollected(currency, feeRecipient, amount);
        return abi.encode(amount);
    }
}
