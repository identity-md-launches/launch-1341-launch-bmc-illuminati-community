# BMC Illuminati (BMC) — Uniswap v4 launch

A fixed-supply ERC-20 on Ethereum, paired with native ETH on Uniswap v4, with a hook that sends
1% of every buy's ETH to the community wallet and burns 1% of every sale's BMC. Plus an ownerless
swap router and a static website.

| Contract | File | Launched? | Purpose |
| --- | --- | --- | --- |
| `BMCToken` | `src/BMCToken.sol` | yes (`$token`) | "BMC Illuminati" / "BMC", 1,000,000,000 × 10^18 minted once to the deployer (the factory). Burnable only. |
| `BMCHook` | `src/BMCHook.sol` | yes | The pool's hook: buy fee in ETH to the community wallet, sell burn. Immutable, ownerless. |
| `BMCSwapRouter` | `src/BMCSwapRouter.sol` | optional | Ownerless ETH-pool router the website uses for approve-exact-then-swap. Stateless; any v4 router works too. |
| `HookFlags`, `HookDeployer` | `src/` | no (internal libraries) | Address-bit helpers and CREATE2 salt mining for scripts and tests. |

## Launch parameters (what the manifest step fills)

- Chain: Ethereum (chain id 1). Pair: native ETH (`currency0` = zero address, `currency1` = BMC).
- `pool.fee` 12500 (1.25% LP fee: 1% to the launcher, 0.25% to IMD), `pool.tickSpacing` 60.
- Opening price: the deployer derives it from a 10 ETH market cap for the whole supply.
- Supply split (done by the factory, not by these contracts): 10% to the swarm's MerkleDistributor,
  88% into the pool, 2% to the launcher wallet.
- `BMCToken` constructor: no arguments.
- `BMCHook` constructor arguments, in order:

| # | Argument | Manifest value | Meaning |
| --- | --- | --- | --- |
| 1 | `_poolManager` | `$poolManager` | The chain's Uniswap v4 PoolManager. Never hardcoded. |
| 2 | `_token` | `$token` | The launch token, deployed by the factory just before the hook. |
| 3 | `_feeRecipient` | `0x83027AD9d0D5374335086c539dADD1db983441B0` | Community wallet that receives the ETH buy fee (the brief's address; also `$owner`). |
| 4 | `_buyFeeBps` | `100` | 1% of the ETH side of every buy. |
| 5 | `_sellBurnBps` | `100` | 1% of the BMC in every sale is burned. |

- `BMCSwapRouter` constructor: `$poolManager` only.
- Hook address bits (mined by the deployer): `beforeInitialize | beforeSwap | afterSwap |
  beforeSwapReturnDelta | afterSwapReturnDelta` = `0x20CC` (8396). `BMCHook.HOOK_FLAGS` exposes it and
  the test suite checks it equals `getHookPermissions()`.
- The constructor makes no external call and needs no address to have code; it only validates its own
  address bits (`Hooks.validateHookPermissions`), so a wrong salt reverts the deployment instead of
  producing a hook the PoolManager would never call.

## How the hook works

- **Buy (ETH → BMC, `zeroForOne`)**: 1% of the ETH side. Exact-input: taken in `beforeSwap` off the
  specified input via `beforeSwapReturnDelta`; the pool swaps the other 99%. Exact-output: taken in
  `afterSwap` as 1% of the ETH the pool charged, added to what the swapper owes via
  `afterSwapReturnDelta`. The fee is settled in ETH inside the same swap.
- **Sell (BMC → ETH)**: 1% of the BMC being sold, taken the same two ways, then burned with the
  token's `burn`. `totalSupply()` drops; nothing is parked at the zero address. No ETH fee on sells.
- **Where fees go**: ETH to `feeRecipient` (the community wallet) as native ETH; BMC to nowhere
  (burned, `Transfer(hook, 0x0, amount)`).
- **When the PoolManager cannot pay yet**: a fee is paid from the manager's own balance, and on a pool
  seeded with tokens only the manager holds no ETH until the first buy settles. In that case (and
  symmetrically for BMC on a sell into an ETH-only position) the hook mints itself an ERC-6909 claim
  instead of reverting the trade. `collect()` — callable by anyone, no arguments — redeems whatever
  claims the manager's balance now covers: ETH to the recipient, BMC burned. `pendingEthFees()` and
  `pendingBurns()` show what is waiting. The site exposes `collect()` to the recipient.
- **One pool**: `beforeInitialize` accepts exactly one pool, native ETH against `_token`, at any LP
  fee and tick spacing the manifest names, from any initializer (the factory). A second pool, a
  pool without the token, or a token/token pool is refused. Swaps are never blocked or altered
  otherwise, and liquidity changes and donations are untouched (those callbacks are not enabled).
- **No powers**: no owner, no setters, no pause, no upgrade. All callbacks and `unlockCallback`
  refuse any caller but the PoolManager. Callbacks not enabled in the address also revert for the
  PoolManager so a mis-set bit can never pass silently. Runtime code contains no `DELEGATECALL`,
  `CALLCODE` or `SELFDESTRUCT`.

Hook configuration in the Wizard's canonical shape (recorded, not generated):

```json
{"hook":"BaseHook","name":"BMCHook","pausable":false,"currencySettler":false,"safeCast":true,
 "transientStorage":false,"shares":{"options":false},
 "permissions":{"beforeInitialize":true,"afterInitialize":false,"beforeAddLiquidity":false,
 "beforeRemoveLiquidity":false,"afterAddLiquidity":false,"afterRemoveLiquidity":false,
 "beforeSwap":true,"afterSwap":true,"beforeDonate":false,"afterDonate":false,
 "beforeSwapReturnDelta":true,"afterSwapReturnDelta":true,"afterAddLiquidityReturnDelta":false,
 "afterRemoveLiquidityReturnDelta":false},"access":"none (immutable, ownerless)","info":{"license":"MIT"}}
```

`beforeSwapReturnDelta` is justified: it only ever returns a positive specified delta equal to the
fee, bounded by the rate cap (≤ 50%, launched at 1%), so a swap can never become a no-op and the
swapper always receives the pool's output for the remaining 99%. The hook is written directly
against `IHooks` from v4-core rather than v4-periphery's `BaseHook` to keep the vendored
dependency set small; the behaviour is the same.

## What the brief asked that the token does not do

The brief puts fees on the token's trades; the launch token itself stays a plain ERC-20 (no fee,
limit, pause, mint, owner). All fee logic lives in the hook, which only sees swaps in its pool.
A transfer outside the pool, or a trade on another venue, pays nothing and burns nothing.
`burn`/`burnFrom` (OpenZeppelin `ERC20Burnable`) are the only supply-changing functions and act on
the caller's own balance or allowance; the hook uses `burn` on tokens it has already taken.

## Assumptions and known behaviour

- The community wallet is an externally owned account. The ETH fee is pushed with a plain call
  inside the swap. If the recipient were a contract that rejects ETH, every direct-pay buy would
  revert; the claim path (`collect`) would also fail to pay it. Immutable, so choose an EOA.
- On an exact-input swap the fee is 1% of the amount specified, booked before the fill. If a swap
  only partially fills (liquidity exhausted or a price limit hit), the fee is still 1% of what was
  requested. With full-range or deep liquidity this does not arise.
- The recipient receives ETH mid-swap. The PoolManager is unlocked at that moment; a contract
  recipient could call it, but the hook keeps no balances and the swapper's own deltas must still net
  to zero, so there is nothing for it to take. With an EOA this is moot.
- Fee rounding is floor division in basis points; dust below 100 wei pays no fee.
- `collect()` can be called by anyone at any time; it only moves claims to their fixed destinations.
- The hook holds nothing between transactions: no ETH (`receive` is absent), and BMC only for the
  instant between `take` and `burn`.
- The 1.25% LP fee and its 1%/0.25% split are the launch policy's and are collected and claimed
  through IMD's launch fee contracts, not through anything here.
- A swap on the hook's pool costs roughly 60–90k gas more than a hookless swap (two callbacks, one
  `take`/`mint`, one `burn` on sells).

## Operational responsibilities

| Who | What |
| --- | --- |
| Launch factory / manifest step | Deploys `BMCToken` then `BMCHook` at a mined address with the arguments above, opens the ETH/BMC pool at fee 12500 / spacing 60, seeds 88%, sends 10% to the MerkleDistributor and 2% to the launcher. |
| Site publisher | After launch, fills `site/config.json` (token, hook, router, pool id, Uniswap pool link, community links, the LP-fee claim contract) and publishes `site/` at `bmcilluminati.sites.imd.fun`. The site is static: `index.html`, `app.js`, `styles.css`, `config.json`. |
| Anyone | Calls `BMCHook.collect()` when `pendingEthFees()` or `pendingBurns()` is non-zero (only happens while the manager's balance was short at trade time). The site offers the button to the recipient. |
| Launcher (`0x8302…41B0`) | Claims the 1% LP-fee share from IMD's launch fee contract; the site's "Claim 1% LP fee share" button calls it once `launcherFeeClaim` in `config.json` names the contract, ABI fragment and arguments. |
| Independent reviewer | Adversarial review before release: tests passing are not an audit. Slither/Mythril did not run here (not available offline); only `forge build`, `forge test` and `forge fmt --check` ran. |

### After launch: site settings (`site/config.json`)

| Key | Set to | Where it comes from |
| --- | --- | --- |
| `token`, `hook`, `router`, `poolManager`, `poolId` | Deployed addresses and the pool id | The launch record / `launch.json` output. |
| `links.uniswap` | The pool's page on app.uniswap.org | Explore → Pools → the ETH/BMC v4 pool. |
| `links.telegram`, `links.x`, `links.docs` | Community links | The requester. |
| `launcherFeeClaim` | `{address, abi, method, args}` of IMD's LaunchFees claim | The network's launch fee contract for this launch. Until set, the button is disabled. |
| `rpcUrl` | A public Ethereum JSON-RPC endpoint | Default: publicnode; change if rate-limited. |

Nothing in the contracts needs any post-launch setting: there are no owner setters.

## Website

`site/` is a dependency-free static page (ethers v6 from a CDN). It shows name, symbol, contract,
initial supply, total supply after burns, circulating supply, burned amount, hook totals, the live
Uniswap pool link, an explanation of the 1% buy fee and 1% sell burn, community links and buy/sell
forms. A connected wallet sees its ETH and BMC balances, can quote and buy (exact ETH in, slippage
bound from a simulated call), approve exactly the amount being sold and sell, and — if it is the fee
recipient — collect pending hook fees and claim the launcher's LP-fee share. There are no admin
actions. Until `config.json` has addresses the page shows a "waiting for the launch record" notice.

## Build, test, format

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"` (the PoolManager uses transient
storage), `via_ir = true` with `optimizer_runs = 44444444` (v4-core's own settings, needed for the
PoolManager to fit under the size limit in tests), `bytecode_hash = "none"` and `cbor_metadata =
false` so the built bytes are reproducible. No `ffi`, no `fs_permissions`.

Dependencies are vendored as ordinary files under `lib/` (no submodules): `v4-core` 1.0.2 (`src/`,
`test/utils/CurrencySettler.sol`, licences), the `forge-std`, `solmate` and OpenZeppelin trees
bundled with it, and OpenZeppelin Contracts 5.6.1 (`contracts/token`, `utils`, `interfaces`,
`access`). Remappings are in `remappings.txt`. One local patch: forge-std 1.9.3 removed
`fail(string)`, which the launch floor tests call, so `lib/forge-std/src/StdAssertions.sol` restores
that one function exactly as 1.8.x defined it (marked with a comment).

### Tests (48, all passing)

- `test/BMCToken.t.sol`: name/symbol/decimals/supply, supply minted to the deployer, exact transfers,
  no mint, no owner/pause, burn reduces supply, burn failures.
- `test/BMCHook.t.sol` on a real `PoolManager` with the hook at a mined address:
  permissions equal address bits and `HOOK_FLAGS`; constructor rejects zero addresses, rates above
  the cap, and an address without the bits; no owner/setters; every callback and `unlockCallback`
  refuse non-PoolManager callers; unused callbacks revert even for the PoolManager; initialize from
  any factory address; second pool, pool without the token, and token/token pool refused; buy
  exact-in (1% of ETH to the wallet, 99% to the pool) and exact-out (fee = 1% of the pool's ETH);
  sell exact-in (1% of tokens burned from `totalSupply`, nothing at the zero address) and exact-out;
  fuzzed exact fee and burn maths; round trip; `collect` with nothing pending; liquidity add/remove
  untouched. On a fresh PoolManager seeded with tokens only: first buy books an ETH claim, `collect`
  pays it, anyone may collect, later buys pay directly, exact-output first buy. On an ETH-only
  position: first sale books a BMC claim and `collect` burns it, exact-output variant.
- `test/BMCSwapRouter.t.sol`: slippage reverts leave no fee/burn, zero amounts, allowance required
  and exact allowance suffices, router holds nothing after the four swap shapes, non-ETH pool
  refused, callback access.
- `test/Deploy.t.sol`: the script's `deploy(Config)` function (constants, no environment) places the
  hook on a flagged address, wires token/recipient/rates, and the factory can initialize the pool.

The protected floor tests under `.imd/reads/protected/univ4_hook/` were also run locally with the
launch-like environment (hook creation code built against a token probe, flags 8396, fee 12500,
spacing 60, native pair) and pass; they expect `src/HookFlags.sol` and `test/mocks/MockERC20.sol`,
both provided.

## Deploy script

`script/Deploy.s.sol` (`DeployBMC`) is a local/fork rehearsal only. `deploy(Config)` takes the
PoolManager, recipient and rates as arguments (tests call it directly); `run()` reads
`POOL_MANAGER` and `FEE_RECIPIENT` from the environment and uses the launch rates (100/100). The
real launch is performed by the IMD factory from the manifest; this repository holds no keys and
broadcasts nothing.

## Security notes (eth-security / uniswap-v4-security checklists applied)

- Caller verification on every callback; `sender` never trusted for identity (not needed).
- Delta accounting: each fee path does exactly one `take` or `mint` for the amount it returns, so
  the hook's net delta is zero on every path; tests assert the hook ends each swap holding nothing.
- No unbounded loops, no external calls except to the PoolManager and the token's `burn`.
- No oracles, no randomness, no reentrancy-sensitive state (the only storage writes are the one-time
  pool attachment and monotonic totals).
- No hardcoded chain addresses; the PoolManager and token are constructor arguments.
- Risk score (guide's rubric): permissions HIGH+MEDIUM+CRITICAL+HIGH+LOW, external calls 2, state 1,
  upgrade 0, token handling 1 → medium. A professional review is recommended before launch.
