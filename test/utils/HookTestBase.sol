// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../../src/HookMiner.sol";

/// @notice Local fixture for native ETH/token pools and real CREATE2 hook deployment.
abstract contract HookTestBase is Test {
    IPoolManager internal manager;
    MockERC20 internal token;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolKey internal key;

    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    int24 internal constant TICK_SPACING = 60;
    int256 internal constant FULL_RANGE_LIQUIDITY = 1e24;

    error HookDeploymentFailed();
    error InvalidSwapAmount();

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        token = new MockERC20("Hook Test Token", "HTT", 18);
        token.mint(address(this), 1e27);
        vm.deal(address(this), 1e27);
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function deployHook(bytes memory creationCode, bytes memory args, uint160 flags) internal returns (IHooks hook) {
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, args);
        bytes memory initCode = abi.encodePacked(creationCode, args);
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(deployed) {
                // Preserve constructor errors for reusable negative tests.
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        if (deployed != expected || deployed.code.length == 0) revert HookDeploymentFailed();
        hook = IHooks(deployed);
    }

    function initPool(IHooks hook) internal returns (PoolKey memory) {
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, TICK_SPACING, hook);
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: uint256(FULL_RANGE_LIQUIDITY)}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: FULL_RANGE_LIQUIDITY,
                salt: bytes32(0)
            }),
            ""
        );
        return key;
    }

    function swapExactInputZeroForOne(uint256 amountIn) internal returns (BalanceDelta) {
        return _swap(true, -_checkedAmount(amountIn), amountIn);
    }

    function swapExactInputOneForZero(uint256 amountIn) internal returns (BalanceDelta) {
        return _swap(false, -_checkedAmount(amountIn), 0);
    }

    /// @param nativeBudget ETH forwarded for actual input plus hook fee; unused ETH is refunded.
    function swapExactOutputZeroForOne(uint256 amountOut, uint256 nativeBudget) internal returns (BalanceDelta) {
        return _swap(true, _checkedAmount(amountOut), nativeBudget);
    }

    function swapExactOutputOneForZero(uint256 amountOut) internal returns (BalanceDelta) {
        return _swap(false, _checkedAmount(amountOut), 0);
    }

    function _checkedAmount(uint256 amount) private pure returns (int256) {
        if (amount == 0 || amount > uint256(type(int256).max)) revert InvalidSwapAmount();
        return int256(amount);
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint256 nativeValue) internal returns (BalanceDelta) {
        return swapRouter.swap{value: nativeValue}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    receive() external payable {}
}
