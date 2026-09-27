# Foundry v4 hook kit

A local development kit for **Uniswap v4-core 1.0.2**, Solidity **0.8.26**, and the **Cancun EVM**. It includes a CREATE2 permission miner, a native ETH/ERC20 pool fixture, and a hook that charges a fixed 1% fee. No deployment or broadcast is part of this project.

## Build and test offline

Install Foundry and provision solc 0.8.26 on the machine before disconnecting from the network. All Solidity dependencies are already ordinary files in `lib/`; no package installation, submodule checkout, RPC endpoint, wallet, or environment variables are needed.

```sh
forge build
forge test
forge fmt --check
```

To explicitly prohibit compiler downloads, use `forge build --offline` and `forge test --offline`. `foundry.toml` pins the compiler version, enables optimization and via-IR, and targets Cancun because v4 uses transient storage. FFI and filesystem cheatcode permissions are disabled. The elevated test gas limit accommodates the bounded salt search; it is not a suggested transaction gas limit.

The [dependency manifest](lib/dependencies.json) records exact commits and archive SHA-256 hashes. v4-core is pinned to the npm 1.0.2 release's git commit, `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`. forge-std, Solmate, and OpenZeppelin match that commit's dependency pins; ds-test supports Solmate's test sources. The v4-core `src/` and `test/` trees, including `test/utils/Deployers.sol`, are vendored. Upstream FFI binaries, package-manager dependencies, repository metadata, and CI configuration are excluded. Upstream suites that need those external tools are not run by this kit.

An optional maintainer command, `python3 tools/vendor_dependencies.py`, refreshes the same source snapshots from checksum-verified archives. It needs network access; **normal builds do not invoke it**. Review and include refreshed files with the project. Dependency licenses remain alongside the source. In particular, v4-core contains BUSL-1.1 code and Solmate contains AGPL code; this kit's MIT license does not replace their licenses.

## Reuse the fixture

Derive tests from [HookTestBase](test/utils/HookTestBase.sol), call `super.setUp()`, deploy the hook through `deployHook`, then call `initPool`:

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
}
```

The fixture creates a fresh PoolManager owned by the test, an 18-decimal MockERC20 with `10^27` units minted to the test, and v4-core's `PoolSwapTest` and `PoolModifyLiquidityTest` routers. It funds the test with `10^27` wei and approves both routers for the token. No protocol fee controller is configured. Every test receives independent state.

`initPool` stores and returns `key`, with native ETH (`Currency.wrap(address(0))`) as currency0 and the token as currency1. Its static LP fee is 3000 (0.30%), tick spacing is 60, and starting `sqrtPriceX96` is `2^96` (1:1 raw units, also 1:1 whole tokens here). It adds `10^24` liquidity over ticks **-887220 to 887220**, the full usable range for this spacing. The liquidity position belongs to the modify-liquidity router.

| Helper | Operation | ETH forwarded |
| --- | --- | --- |
| `swapExactInputZeroForOne(amountIn)` | ETH → token, exact input | `amountIn` |
| `swapExactInputOneForZero(amountIn)` | token → ETH, exact input | zero |
| `swapExactOutputZeroForOne(amountOut, nativeBudget)` | ETH → token, exact output | explicit budget including hook fee |
| `swapExactOutputOneForZero(amountOut)` | token → ETH, exact output | zero |

Each helper returns the swapper's final `BalanceDelta`, settles actual tokens/ETH, and takes output as tokens/ETH. Excess ETH is refunded by the test router. Amounts must be nonzero and fit int256. Price limits are the extremes supported by core; these helpers are test tools, not production slippage protection. A constrained or depleted pool can partially fill a swap. Integration code must supply appropriate price limits and enforce its own final input/output bounds. Native exact-output callers must budget for actual input, the LP fee, and the hook fee.

## Mine and validate permissions

[HookMiner.find](src/HookMiner.sol) searches integer salts `0` through `160443`, in order. It hashes the exact `creationCode ++ constructorArgs`, then computes the standard CREATE2 address from `0xff ++ deployer ++ salt ++ initCodeHash`. It requires an exact match of all 14 permission bits, including disabled permissions, and skips addresses that already have code. Bits above `Hooks.ALL_HOOK_MASK` revert with `FlagsOutOfRange()`; exhaustion reverts with `HookMinerNotFound()`.

`deployer` is the address executing the CREATE2 opcode. In the fixture it is `address(this)`, the test contract. A future factory would require mining with that factory's address and its exact init code. Compiler settings, metadata, constructor arguments, or creation-code changes can change the result. A salt is never a portable guarantee across these changes. If the bounded search is exhausted, change an authorized deployment parameter or use a separately designed search tool. The empty-code check alone cannot detect every CREATE2 failure, such as an occupied account nonce. `deployHook` verifies successful deployment and propagates constructor reverts.

The example constructor calls core's `Hooks.validateHookPermissions`. The only enabled bits are `afterSwap` (`1 << 6`) and `afterSwapReturnDelta` (`1 << 2`), for an exact mask of **0x0044**. Other callback selectors are intentionally absent. New hooks must implement the callbacks they enable and validate their own permission sets. The miner validates bit range, not semantic compatibility between callbacks and return-delta flags.

## FlatFeeHook accounting

[FlatFeeHook](src/examples/FlatFeeHook.sol) takes `constructor(IPoolManager manager, address feeRecipient)`. Both addresses must be nonzero and are immutable. Use a trusted v4-core 1.0.x PoolManager; the constructor only checks nonzero, not manager identity or bytecode. The recipient must accept the currencies collected, including ETH when applicable.

Only the configured manager can call `afterSwap` or `unlockCallback`. For each swap, the hook computes `floor(abs(unspecifiedDelta) / 100)` from the core swap delta before the hook fee. It returns this amount as a **positive** afterSwap delta and calls `poolManager.mint(address(this), currency.toId(), fee)` for the same amount. The mint creates a temporary debit that the returned delta cancels. If rounding produces zero, it does not mint.

| Mode | Fee base and currency | Effect on swapper |
| --- | --- | --- |
| Exact input, zeroForOne | Gross token output, currency1 | Receives output minus fee |
| Exact input, oneForZero | Gross ETH output, currency0 | Receives output minus fee |
| Exact output, zeroForOne | ETH input owed to pool, currency0 | Pays input plus fee |
| Exact output, oneForZero | Token input owed to pool, currency1 | Pays input plus fee |

The 1% hook fee is separate from the pool's 0.30% LP fee. Exact-output fees use the actual input owed to core, including the LP fee. Fees are not recursively charged on themselves. A base below 100 smallest currency units rounds to zero. Arithmetic widens int128 to int256 before taking the absolute value.

The tests read the PoolManager's `Swap` event, emitted before the hook, as an independent accounting reference. For each currency they verify:

```text
swapper balance change + increase in hook claims + pool economic change = 0
pool economic change = manager custody change - increase in hook claims
pool economic change = -pre-hook swap delta
```

Claims remain backed by assets held in the manager. Adding claims to raw manager custody without subtracting their backing would double-count them. Tests also verify real transfers, specified swap amounts, native refunds, and zero transient debts after settlement. Fuzz cases vary size and direction; deterministic cases cover all four modes, fee rounding, permission/address failures, occupied salts, the final permitted salt, and exhausted searches.

## Collection and responsibilities

Anyone may call `collect(currency)`. It opens its own manager unlock, reads **all** claims the hook holds for that currency, burns them, and takes the underlying assets directly to the immutable recipient. It returns the collected amount and emits `FeesCollected`. There is no caller reward, owner, recipient setter, fee setter, or administrative withdrawal. Claims are aggregated across every pool using the same hook and include claims transferred to the hook by others.

Collection must happen while the manager is locked. Calling it inside a swap, another unlock, or a recipient callback during collection reverts with core's `AlreadyUnlocked`. Claims are burned before the recipient transfer; if the recipient rejects payment, the transaction rolls back and claims remain intact. Empty collection succeeds with amount zero. Tests cover native and ERC20 payouts, arbitrary collectors, repeat collection, failed payout rollback, and nested-unlock rejection.

The example uses static-fee pools and rejects a dynamic-fee key in `afterSwap`; it does not implement dynamic fee updates. With only afterSwap permissions it cannot prevent someone from initializing an unusable dynamic-fee pool with its address. It has no pool allowlist. Pool creators choose their keys and liquidity; integrators must select the intended pool and account for the hook fee in quotes and slippage bounds.

Operators are responsible for choosing a trusted manager and permanent recipient, supplying liquidity and swap funding, monitoring accumulated claims, and submitting collection calls when useful. Direct ERC20 or ETH transfers to the hook are not a fee-payment mechanism; it has no generic asset rescue function. Nonstandard tokens (transfer fees, rebasing, unusual callbacks) are outside this fixture's assumptions. No external transactions are authorized or executed here. Before any release involving user funds, obtain an independent adversarial review; passing these tests is not a security audit.

Protocol references: [v4-core 1.0.2 source](https://github.com/Uniswap/v4-core/tree/59d3ecf53afa9264a16bba0e38f4c5d2231f80bc), [hook deployment guide](https://developers.uniswap.org/docs/protocols/v4/guides/hooks/hook-deployment), and [swap hook guide](https://developers.uniswap.org/docs/protocols/v4/guides/hooks/swap-hooks).
