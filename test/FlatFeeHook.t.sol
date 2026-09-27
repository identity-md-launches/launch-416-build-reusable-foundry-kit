// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";
import {FlatFeeHook} from "../src/examples/FlatFeeHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract RejectingRecipient {
    receive() external payable {
        revert("no ETH");
    }
}

contract FlatFeeHookTest is HookTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant FLAGS = Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    FlatFeeHook internal hook;
    address internal recipient = address(0xBEEF);

    struct Balances {
        uint256 user0;
        uint256 user1;
        uint256 manager0;
        uint256 manager1;
        uint256 claims0;
        uint256 claims1;
    }

    function setUp() public override {
        super.setUp();
        hook = FlatFeeHook(address(deployHook(type(FlatFeeHook).creationCode, abi.encode(manager, recipient), FLAGS)));
        initPool(IHooks(address(hook)));
    }

    function testPermissionsAndFixture() public view {
        Hooks.Permissions memory expected;
        expected.afterSwap = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.feeRecipient(), recipient);
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(token));
        assertEq(key.fee, 3000);
        assertEq(key.tickSpacing, 60);
        (uint160 price, int24 tick,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(price, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(lpFee, 3000);
        assertEq(manager.getLiquidity(key.toId()), uint256(FULL_RANGE_LIQUIDITY));
        (uint128 position,,) = manager.getPositionInfo(key.toId(), address(modifyLiquidityRouter), -887220, 887220, 0);
        assertEq(position, uint256(FULL_RANGE_LIQUIDITY));
    }

    // External wrapper gives expectRevert an actual call boundary.
    function deployForTest(IPoolManager manager_, address recipient_, uint160 flags) external returns (address) {
        return address(deployHook(type(FlatFeeHook).creationCode, abi.encode(manager_, recipient_), flags));
    }

    function testConstructorRejectsWrongAddressBits() public {
        uint160 wrongFlags = Hooks.AFTER_SWAP_FLAG;
        (address wrong,) =
            HookMiner.find(address(this), wrongFlags, type(FlatFeeHook).creationCode, abi.encode(manager, recipient));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        this.deployForTest(manager, recipient, wrongFlags);
        assertEq(wrong.code.length, 0);
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(FlatFeeHook.ZeroAddress.selector);
        this.deployForTest(IPoolManager(address(0)), recipient, FLAGS);
        vm.expectRevert(FlatFeeHook.ZeroAddress.selector);
        this.deployForTest(manager, address(0), FLAGS);
    }

    function testCallbacksRejectUnauthorizedCallers() public {
        vm.expectRevert(FlatFeeHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1e18, 1), toBalanceDelta(-100, 100), "");
        vm.expectRevert(FlatFeeHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(key.currency0));
    }

    function testRejectsDynamicFeeCallback() public {
        PoolKey memory dynamicKey = key;
        dynamicKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.prank(address(manager));
        vm.expectRevert(FlatFeeHook.DynamicFeeNotSupported.selector);
        hook.afterSwap(address(this), dynamicKey, SwapParams(true, -1e18, 1), toBalanceDelta(-100, 100), "");
    }

    function testExactInputZeroForOne() public {
        _assertSwap(true, true, 1e18);
    }

    function testExactInputOneForZero() public {
        _assertSwap(true, false, 1e18);
    }

    function testExactOutputZeroForOne() public {
        _assertSwap(false, true, 1e18);
    }

    function testExactOutputOneForZero() public {
        _assertSwap(false, false, 1e18);
    }

    function testFuzzFeeAndConservation(bool exactInput, bool zeroForOne, uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 100, 1e21);
        _assertSwap(exactInput, zeroForOne, amount);
    }

    function testTinySwapsRoundFeeToZeroInEveryMode() public {
        _assertSwap(true, true, 10);
        _assertSwap(true, false, 10);
        _assertSwap(false, true, 10);
        _assertSwap(false, false, 10);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }

    function testCollectBothCurrenciesIsPermissionlessAndRepeatable() public {
        _assertSwap(true, true, 1e18);
        _assertSwap(true, false, 2e18);
        _assertSwap(false, true, 3e18);
        _assertSwap(false, false, 4e18);
        _assertCollect(key.currency0);
        _assertCollect(key.currency1);
        assertEq(hook.collect(key.currency0), 0);
        assertEq(hook.collect(key.currency1), 0);
        // Accrual resumes after collection.
        _assertSwap(false, true, 1e18);
        _assertCollect(key.currency0);
    }

    function testRecipientTransferRevertPreservesClaims() public {
        RejectingRecipient rejecting = new RejectingRecipient();
        hook = FlatFeeHook(
            address(deployHook(type(FlatFeeHook).creationCode, abi.encode(manager, address(rejecting)), FLAGS))
        );
        initPool(IHooks(address(hook)));
        _assertSwap(true, false, 1e18);
        uint256 claims = manager.balanceOf(address(hook), 0);
        uint256 balance = address(manager).balance;
        vm.expectRevert();
        hook.collect(key.currency0);
        assertEq(manager.balanceOf(address(hook), 0), claims);
        assertEq(address(manager).balance, balance);
        assertEq(address(rejecting).balance, 0);
        assertFalse(manager.isUnlocked());
    }

    function testCollectCannotNestInsideAnotherUnlock() public {
        _assertSwap(true, false, 1e18);
        uint256 claims = manager.balanceOf(address(hook), 0);
        manager.unlock("");
        assertEq(manager.balanceOf(address(hook), 0), claims);
        _assertCollect(key.currency0);
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        hook.collect(key.currency0);
        return "";
    }

    function testInsufficientNativeBudgetRevertsAtomically() public {
        Balances memory before_ = _balances();
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        vm.expectRevert();
        this.underfundedSwap();
        assertEq(abi.encode(_balances()), abi.encode(before_));
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertFalse(manager.isUnlocked());
    }

    function underfundedSwap() external {
        swapExactOutputZeroForOne(1e18, 0);
    }

    function _assertCollect(Currency currency) internal {
        uint256 claims = manager.balanceOf(address(hook), currency.toId());
        assertGt(claims, 0);
        uint256 beforeRecipient = currency.balanceOf(recipient);
        uint256 beforeManager = currency.balanceOf(address(manager));
        address collector = address(0xCA11);
        uint256 beforeCollector = currency.balanceOf(collector);
        vm.prank(collector);
        assertEq(hook.collect(currency), claims);
        assertEq(currency.balanceOf(recipient) - beforeRecipient, claims);
        assertEq(beforeManager - currency.balanceOf(address(manager)), claims);
        assertEq(currency.balanceOf(collector), beforeCollector);
        assertEq(manager.balanceOf(address(hook), currency.toId()), 0);
        assertEq(manager.currencyDelta(address(hook), currency), 0);
        assertFalse(manager.isUnlocked());
    }

    function _assertSwap(bool exactInput, bool zeroForOne, uint256 amount) internal {
        Balances memory before_ = _balances();
        vm.recordLogs();
        BalanceDelta swapper;
        if (exactInput) {
            swapper = zeroForOne ? swapExactInputZeroForOne(amount) : swapExactInputOneForZero(amount);
        } else {
            swapper = zeroForOne ? swapExactOutputZeroForOne(amount, amount * 2) : swapExactOutputOneForZero(amount);
        }
        BalanceDelta raw = _rawPoolDelta(vm.getRecordedLogs());
        Balances memory after_ = _balances();
        int256 claims0 = int256(after_.claims0 - before_.claims0);
        int256 claims1 = int256(after_.claims1 - before_.claims1);

        // Explicit four-case oracle, using the core event emitted before afterSwap.
        int256 unspecified;
        bool feeIn0;
        if (exactInput && zeroForOne) {
            unspecified = raw.amount1();
        } else if (exactInput && !zeroForOne) {
            unspecified = raw.amount0();
            feeIn0 = true;
        } else if (!exactInput && zeroForOne) {
            unspecified = raw.amount0();
            feeIn0 = true;
        } else {
            unspecified = raw.amount1();
        }
        int256 fee = (unspecified < 0 ? -unspecified : unspecified) / 100;
        assertEq(claims0, feeIn0 ? fee : int256(0));
        assertEq(claims1, feeIn0 ? int256(0) : fee);
        if (amount >= 1e18) assertGt(fee, 0);
        if (amount == 10) assertEq(fee, 0);

        int256 user0 = int256(after_.user0) - int256(before_.user0);
        int256 user1 = int256(after_.user1) - int256(before_.user1);
        int256 custody0 = int256(after_.manager0) - int256(before_.manager0);
        int256 custody1 = int256(after_.manager1) - int256(before_.manager1);
        assertEq(user0, int256(swapper.amount0()));
        assertEq(user1, int256(swapper.amount1()));
        assertEq(user0 + claims0 - int256(raw.amount0()), 0, "currency0 economic conservation");
        assertEq(user1 + claims1 - int256(raw.amount1()), 0, "currency1 economic conservation");
        // Custody includes backing for claims; subtract claims to isolate pool value.
        assertEq(custody0 - claims0, -int256(raw.amount0()));
        assertEq(custody1 - claims1, -int256(raw.amount1()));
        assertEq(user0 + custody0, 0, "native settlement conservation");
        assertEq(user1 + custody1, 0, "token settlement conservation");
        assertEq(zeroForOne ? int256(swapper.amount0()) < 0 : int256(swapper.amount1()) < 0, true);
        int256 specified = exactInput
            ? (zeroForOne ? int256(swapper.amount0()) : int256(swapper.amount1()))
            : (zeroForOne ? int256(swapper.amount1()) : int256(swapper.amount0()));
        assertEq(specified, exactInput ? -int256(amount) : int256(amount));
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(swapRouter), key.currency0), 0);
        assertEq(manager.currencyDelta(address(swapRouter), key.currency1), 0);
        assertEq(address(swapRouter).balance, 0);
        assertEq(token.balanceOf(address(swapRouter)), 0);
        assertFalse(manager.isUnlocked());
    }

    function _balances() internal view returns (Balances memory) {
        return Balances(
            address(this).balance,
            token.balanceOf(address(this)),
            address(manager).balance,
            token.balanceOf(address(manager)),
            manager.balanceOf(address(hook), key.currency0.toId()),
            manager.balanceOf(address(hook), key.currency1.toId())
        );
    }

    function _rawPoolDelta(Vm.Log[] memory logs) internal view returns (BalanceDelta raw) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                raw = toBalanceDelta(amount0, amount1);
                ++count;
            }
        }
        assertEq(count, 1, "one core swap event required");
    }
}
