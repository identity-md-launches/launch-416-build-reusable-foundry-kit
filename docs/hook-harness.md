# Local hook harness guide

This kit runs a Uniswap v4-core 1.0.2 PoolManager in Foundry tests. It supplies a bounded CREATE2 permission miner, a native ETH/test-token pool fixture, and `FlatFeeHook`, which takes a fixed 1% swap fee as ERC-6909 claims.

**Local development only.** There is no deployment script or deployed address, no audit, and no production slippage protection. `MockERC20`, `PoolSwapTest`, and `PoolModifyLiquidityTest` are test utilities. The hook accepts any static-fee pool key using its address; it does not check a pool allowlist. Keep real funds out of this example.

## Run it from a fresh clone

Install Foundry with Forge and make Solidity compiler 0.8.26 available. The Solidity source dependencies are committed as ordinary files under `lib/`, so these commands need no dependency download, submodule, RPC, wallet, or environment variable:

```sh
forge build
forge test
forge test --match-contract FlatFeeHookTest --match-test testExactInputZeroForOne -vv
```

The last command is a short usage example: it runs one ETH-to-token swap through the fixture and checks the fee and balances. With solc 0.8.26 already installed, add `--offline` to either build or test to prohibit compiler downloads. `foundry.toml` pins Cancun, optimization, and via-IR; v4-core uses transient storage. The high test gas limit permits a bounded salt search and is not a transaction gas recommendation.

The committed [dependency manifest](../lib/dependencies.json) identifies the exact v4-core, forge-std, Solmate, OpenZeppelin, and ds-test snapshots. `tools/vendor_dependencies.py` is an optional **networked maintainer refresh**, not part of build or test. It would change `lib/` and should only be used in work authorized to update dependencies. The upstream `lib/v4-core/test/` tree is present, but upstream tests needing excluded FFI binaries or package-manager assets are outside this kit's test run.

## Make a test using the fixture

Derive from [`HookTestBase`](../test/utils/HookTestBase.sol). In your `setUp`, call `super.setUp()`, mine and deploy a hook with the exact creation code and ABI-encoded constructor arguments, then initialize a pool:

```solidity
import {HookTestBase} from "./utils/HookTestBase.sol";
import {FlatFeeHook} from "../src/examples/FlatFeeHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract MyHookTest is HookTestBase {
    FlatFeeHook internal hook;

    function setUp() public override {
        super.setUp();
        hook = FlatFeeHook(address(deployHook(
            type(FlatFeeHook).creationCode,
            abi.encode(manager, address(0xBEEF)),
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        )));
        initPool(IHooks(address(hook)));
    }

    function testSwapAndCollect() public {
        swapExactInputZeroForOne(1 ether);
        uint256 tokenClaims = manager.balanceOf(address(hook), key.currency1.toId());
        assertGt(tokenClaims, 0);
        assertEq(hook.collect(key.currency1), tokenClaims);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }
}
```

Save this as a new `.t.sol` file under `test/` in your own project, then run `forge test --match-contract MyHookTest`. The snippet's `address(0xBEEF)` is a local test recipient. The fixture gives the test contract `10^27` wei and `10^27` units of an 18-decimal `MockERC20`, deploys a fresh manager and both v4-core test routers, and approves the routers for the test token. `initPool` saves the `PoolKey` in `key`: native ETH is currency0, the test token is currency1, fee is 3000 (0.30%), tick spacing is 60, and initial price is 1:1 in raw units. It supplies `10^24` liquidity across usable ticks -887220 to 887220, owned by the liquidity router.

The four swap helpers use the core router and return the **swapper's final** `BalanceDelta`. For exact input, the specified amount is negative in core's `SwapParams`; for exact output it is positive. `zeroForOne` means ETH to token.

| Helper | Specified amount | Native value sent by fixture |
| --- | --- | --- |
| `swapExactInputZeroForOne(amountIn)` | ETH input | `amountIn`; unused ETH is refunded |
| `swapExactInputOneForZero(amountIn)` | Token input | 0 |
| `swapExactOutputZeroForOne(amountOut, nativeBudget)` | Token output | Explicit budget for actual ETH input and hook fee; unused ETH is refunded |
| `swapExactOutputOneForZero(amountOut)` | ETH output | 0 |

Use a positive amount no larger than `int256.max`. The helpers choose near-extreme sqrt-price limits, so a swap can partially fill if the pool cannot complete it. They do not set a maximum input or minimum output for a trader; an application must supply those checks itself. An insufficient native budget, insufficient balance or approval, invalid pool state, or a hook/core/router revert rolls the swap back.

## Permission mining and deployment

v4-core selects callbacks from the low 14 bits of the hook address. `FlatFeeHook.getHookPermissions()` enables only `afterSwap` and `afterSwapReturnDelta`, producing `0x0044`. The constructor validates the deployed address against exactly those two bits; a hook at a mismatched address reverts with core's `Hooks.HookAddressNotValid`.

[`HookMiner.find`](../src/HookMiner.sol) is an `internal view` library function. It hashes `creationCode ++ constructorArgs` and searches salts `0` through `160443` in order using `keccak256(0xff ++ deployer ++ salt ++ initCodeHash)`. It returns the first address whose masked bits equal the requested flags **exactly** and whose current code length is zero. There is no privileged caller. It reverts with `FlagsOutOfRange()` if any bit lies above `Hooks.ALL_HOOK_MASK` and `HookMinerNotFound()` if the bounded search ends. It does not establish that a code-free account has an unused nonce or that CREATE2 will succeed.

`deployer` must be the contract that executes CREATE2. The fixture passes `address(this)` and checks that deployment produced code at the predicted address. A different deployer, constructor argument, compiler output, or metadata changes the resulting address. Mining a mask alone does not prove that a hook implements its advertised callbacks; the example constructor performs that validation for its own permissions. For an example of negative and boundary cases, run `forge test --match-contract HookMinerTest -vv`.

## Fee and collection flow

The hook receives `afterSwap` from its configured manager. It computes `floor(abs(unspecified pre-hook swap delta) / 100)`. For exact-input swaps the unspecified amount is the gross output; for exact-output swaps it is the actual input owed to the pool, including the pool LP fee. It mints that many claims in the fee currency to itself and returns an equal positive `afterSwap` delta. Amounts with an absolute fee base below 100 smallest units produce zero claims. There is no fee setter or owner.

| Swap | Fee currency | Swapper effect |
| --- | --- | --- |
| Exact input, ETH to token | Token | Output falls by the fee |
| Exact input, token to ETH | ETH | Output falls by the fee |
| Exact output, ETH to token | ETH | Input rises by the fee |
| Exact output, token to ETH | Token | Input rises by the fee |

The hook fee is separate from the pool's 0.30% LP fee. The tests compare the core `Swap` event, emitted before `afterSwap`, with final swapper balances, manager custody, and claim balances. Per currency, `swapper change + claim increase + pool economic change = 0`, where `pool economic change = manager custody change - claim increase`. Claims are backed by assets in manager custody; counting both gross custody and claims as separate assets would count the backing twice. Deterministic tests cover all four modes and tiny swaps; fuzz tests vary amount and direction.

Anyone can call `collect(currency)` after fees accrue. The hook opens its own manager unlock, burns **all** ERC-6909 claims it holds for that currency, and takes the underlying asset directly to its immutable `feeRecipient`. The caller receives nothing. A successful call returns the redeemed amount and emits `FeesCollected`, even if that amount is zero. The claim balance aggregates accrual across pools using this hook and any claims transferred to it. Collection cannot be nested inside an already-open manager unlock. A failed recipient payout reverts the entire transaction, preserving claims. For a local demonstration, run `forge test --match-contract FlatFeeHookTest --match-test testCollectBothCurrenciesIsPermissionlessAndRepeatable -vv`.

## Entry-point reference

The table covers code supplied by this kit. `PoolManager` and test router methods are upstream v4-core APIs with their own checks.

| Entry point | Who can use it and effect | Main failure modes |
| --- | --- | --- |
| `HookMiner.find(deployer, flags, creationCode, constructorArgs)` | Internal library call from a contract; reads candidate addresses, returns `(address, salt)` without deploying. | `FlagsOutOfRange`; `HookMinerNotFound`. A returned address can still fail CREATE2 because the miner checks code length, not nonce. |
| `FlatFeeHook.constructor(manager, recipient)` | Any CREATE2 deployer; fixes both immutable addresses and validates the hook's address bits. | `ZeroAddress` for either zero address; `Hooks.HookAddressNotValid` for any wrong permission bit. It does not authenticate manager code. |
| `poolManager()` and `feeRecipient()` | Public immutable getters; anyone may read them. | No contract-defined revert. |
| `getHookPermissions()` | Public pure getter; anyone may read the two enabled permissions. | No contract-defined revert. |
| `afterSwap(sender, key, params, delta, hookData)` | Only the configured manager; returns the selector and positive fee delta and, if nonzero, mints claims to the hook. | `OnlyPoolManager`; `DynamicFeeNotSupported`; core mint can revert if the manager is locked or accounting is invalid. During a swap, core may wrap a hook revert. |
| `collect(currency)` | Anyone; redeems every claim the hook holds for this currency to the fixed recipient; returns amount. | Core `AlreadyUnlocked` if nested; burn/take or currency transfer can revert, including when the recipient rejects ETH. Failure rolls back. |
| `unlockCallback(data)` | Only the configured manager during `collect`; decodes a `Currency`, burns claims, takes assets, emits `FeesCollected`, returns ABI-encoded amount. | `OnlyPoolManager`; malformed ABI data; core burn/take or recipient transfer failure. It is not a user collection entry point. |
| `HookTestBase.setUp()` | Public Foundry setup method on derived test contracts; creates fresh local fixtures. | Deployment or token approval failure propagates. It is test-only. |
| `HookTestBase.deployHook(code, args, flags)` | Internal helper for derived tests; mines and deploys from the test contract. | Miner errors, constructor revert, CREATE2 failure, or `HookDeploymentFailed` if the result is absent/mismatched. |
| `HookTestBase.initPool(hook)` | Internal helper for derived tests; initializes the native/token pool and supplies full-range liquidity. | Core can reject invalid or duplicate pool keys; liquidity calls can fail for invalid hook behavior, balances, approvals, or settlement. |
| Four `HookTestBase.swap…` helpers | Internal helpers for derived tests; perform the four modes shown above. | `InvalidSwapAmount` for zero or above `int256.max`; pool, hook, router, token, or native settlement errors propagate. No slippage bound is enforced. |
| `HookTestBase.receive()` | Any sender can send native ETH to a derived fixture contract. | No contract-defined revert. Test-only. |

Only `afterSwap` is enabled among `IHooks` callbacks. The other callback selectors are absent, so a direct call to them reverts. Pool creators can still initialize a dynamic-fee pool with this hook address; its `afterSwap` then reverts with `DynamicFeeNotSupported` on a swap. The example has no dynamic-fee update path, administrative rescue, recipient rotation, or pool selection policy. Its behavior with nonstandard tokens and hostile external components is not established by these local tests. Do an independent security review before adapting it for real funds.
