<p align="right">
  <a href="README.md">English</a> | <a href="README.zh.md">中文</a>
</p>

# GambitFi — every swap is a scratch ticket

> A Uniswap V4 Hook submission for the [OKX X Layer **"Hook the Future"** hackathon](https://web3.okx.com/zh-hans/xlayer/build-x-hackathon/hook).

GambitFi turns any Uniswap V4 pool into a self-funding lottery. Each qualifying swap pays a
small lottery fee (default **1%** on the unspecified token) into a per-pool prize pool. A
pseudo-random roll decides whether that swap is "lucky" — if it is, the swapper sweeps the
**entire accumulated prize pool** in the same transaction. No protocol subsidy, no keeper,
no second contract.

The thesis: meme pools, alt-coin pools, and other high-engagement venues are already
playgrounds for speculation. GambitFi makes the engagement part of the protocol itself,
turning aggregate swap volume into a flywheel that funds itself and rewards traders who
keep coming back.

---

## Why this should win

| Judging axis | How GambitFi scores |
|---|---|
| **Innovation** | New asset-level mechanic — not a fee tweak, not another oracle, not a yet-another-AMM. Turns trading itself into a game. |
| **Market value** | Self-funding from real swap volume. Drives stickier liquidity in meme/alt pools. No emissions, no inflation. |
| **Completion** | Live on X Layer testnet with verifiable contract address, full Foundry test suite, end-to-end deploy script. |
| **Composability** | Pure `afterSwap` hook — works with any V4 pool, any router, any frontend. Recipient is configurable via `hookData`. |

---

## Architecture

```
        ┌─────────────┐   swap            ┌────────────────┐
 user ──▶  V4 Router  │ ───────────────▶  │  PoolManager   │
        └─────────────┘                   └──────┬─────────┘
                                                 │ afterSwap(...)
                                                 ▼
                                      ┌────────────────────────┐
                                      │   GambitFiHook         │
                                      │                        │
                                      │  1. take 1% of output  │
                                      │     into hook reserve  │
                                      │  2. roll dice          │
                                      │  3. if win → sweep     │
                                      │     prize pool to      │
                                      │     player             │
                                      └────────────────────────┘
                                                 │
                                                 ▼
                                          prizePool[poolId][currency]
                                          totalTickets[poolId]
```

The hook permissions are exactly two flags:

- `afterSwap` — get called after every swap.
- `afterSwapReturnDelta` — extract the lottery fee from the swap's unspecified token.

Both bits are encoded in the lowest 14 bits of the hook address, which is mined via CREATE2
in [script/DeployGambitFi.s.sol](script/DeployGambitFi.s.sol).

---

## Mechanics in one page

1. On every `afterSwap`, the hook looks at the **unspecified** token of the swap (output for
   exact-input swaps, input for exact-output).
2. If the absolute amount is below `minSwapAmount`, the lottery is skipped — no ticket, no
   fee. Filters dust spam.
3. Otherwise the hook takes `lotteryFeeBps / 10_000` of that amount out of the PoolManager
   into its own ERC-20 reserve via `poolManager.take(...)`. It then bumps
   `prizePool[poolId][currency]` and emits `TicketIssued`.
4. A pseudo-random `roll` is computed from `block.prevrandao`, `block.timestamp`,
   `block.number`, the player address, the pool id, and a monotonic `swapNonce`. If
   `roll % winChance == 0`, the player wins.
5. The winner receives the **full** accumulated prize pool for that token (including their
   own ticket fee from the current swap) via `Currency.transfer`. `LotteryWin` is emitted.
6. The hook returns `(afterSwap.selector, feeAmount)` so the swap accounting correctly
   reflects the extracted lottery fee.

**Recipient override.** When called through a router, the `sender` argument is the router
itself, not the user. To pay out the right address, the hook checks `hookData`: if it is
exactly `abi.encode(address)`, that address becomes the player. Any V4 router that forwards
`hookData` works out of the box.

**Default config** (set at deploy in [DeployGambitFi.s.sol](script/DeployGambitFi.s.sol)):

| Param | Value | Meaning |
|---|---|---|
| `winChance` | `100` | 1 in 100 qualifying swaps wins |
| `lotteryFeeBps` | `100` | 1% ticket fee on unspecified token |
| `minSwapAmount` | `1e15` | swaps below this skip the lottery |
| `MAX_FEE_BPS` (constant) | `1000` | hard cap to prevent absurd configs |

---

## Project layout

```
.
├── src/
│   ├── GambitFiHook.sol         # the hook — afterSwap lottery
│   └── base/
│       └── BaseHook.sol         # minimal BaseHook (constructor flag validation)
├── test/
│   └── GambitFiHook.t.sol       # 8 Foundry tests covering happy + edge paths
├── script/
│   ├── DeployGambitFi.s.sol     # end-to-end deploy + pool init + demo swap
│   └── utils/
│       ├── HookMiner.sol        # CREATE2 salt miner for flag-encoded address
│       ├── Create2Deployer.sol  # minimal CREATE2 factory used by the script
│       └── DemoERC20.sol        # tiny faucet ERC-20 for testnet demo
├── foundry.toml
├── remappings.txt
└── .env.example
```

---

## Build · Test · Deploy

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`).
- An X Layer Sepolia testnet wallet (chainId **1952**) with some test OKB for gas.
  Faucet: <https://www.okx.com/zh-hans/xlayer/faucet>.

### Install + build

```sh
forge install                  # pulls v4-core, v4-periphery, openzeppelin, forge-std
forge build
```

### Run the test suite

```sh
forge test -vv
```

Expected output: **8 passing**.

```
[PASS] test_constructor_revertsOnFeeBpsTooHigh
[PASS] test_constructor_revertsOnZeroWinChance
[PASS] test_permissions_areAfterSwapOnly
[PASS] test_swap_belowMinSwap_skipsLottery
[PASS] test_swap_feeAccumulatesInPrizePool
[PASS] test_swap_hookDataOverridesRecipient_winnerGetsPaid
[PASS] test_swap_multipleSwapsCompoundPrizePool
[PASS] test_swap_winChanceOne_alwaysWinsAndDrainsPrize
```

### Deploy to X Layer testnet

```sh
cp .env.example .env
# edit .env: PRIVATE_KEY, XLAYER_TESTNET_RPC_URL

source .env
forge script script/DeployGambitFi.s.sol:DeployGambitFi \
    --rpc-url "$XLAYER_TESTNET_RPC_URL" \
    --broadcast \
    -vvv
```

The script self-contains everything needed:

1. Deploys a `Create2Deployer` (CREATE2 factory).
2. Deploys a fresh `PoolManager` (owner = deployer).
3. Deploys `PoolModifyLiquidityTest` + `PoolSwapTest` (v4-core test routers).
4. Mints two `DemoERC20` faucet tokens.
5. Mines a CREATE2 salt so the hook address has the right flag bits.
6. Deploys `GambitFiHook` via the factory.
7. Initializes a 0.3% / tickSpacing-60 pool with the hook.
8. Seeds initial liquidity in `[-600, 600]`.
9. Runs one demo swap so the first `TicketIssued` event lands on-chain.

The summary block at the end prints every deployed address.

### Watching the events

```sh
# Tail TicketIssued / LotteryWin events on the deployed hook
cast logs \
    --rpc-url "$XLAYER_TESTNET_RPC_URL" \
    --address <GambitFiHook> \
    'TicketIssued(bytes32,address,address,uint256,uint256,uint256)' \
    'LotteryWin(bytes32,address,address,uint256,uint256)'
```

---

## Deployed addresses

**Network:** X Layer Sepolia testnet (chainId **1952**) ·
Explorer: <https://www.oklink.com/xlayer-test>

| Contract | Address |
|---|---|
| `GambitFiHook`    | [`0xe713718Ee92947e1a9250Be4703fCff8CC850044`](https://www.oklink.com/xlayer-test/address/0xe713718Ee92947e1a9250Be4703fCff8CC850044) |
| `PoolManager`     | [`0xE32384B0f3345eF38899796ce3cFC3BA15f35295`](https://www.oklink.com/xlayer-test/address/0xE32384B0f3345eF38899796ce3cFC3BA15f35295) |
| `Create2Deployer` | [`0xb3397e478AEaeBfdDe81866a0dB57DA256f7F91b`](https://www.oklink.com/xlayer-test/address/0xb3397e478AEaeBfdDe81866a0dB57DA256f7F91b) |
| `Token0 (GDA/GDB)` | [`0x44cAe1db307BdFf17949d36F2E314d8F4eeA3a23`](https://www.oklink.com/xlayer-test/address/0x44cAe1db307BdFf17949d36F2E314d8F4eeA3a23) |
| `Token1 (GDA/GDB)` | [`0xa436331340F69c01032703f8F479DbE7f797f315`](https://www.oklink.com/xlayer-test/address/0xa436331340F69c01032703f8F479DbE7f797f315) |
| `PoolModifyLiquidityTest` | [`0x28863Ac7C002fD6cD875FbA9cf34eacde8Ac4cEe`](https://www.oklink.com/xlayer-test/address/0x28863Ac7C002fD6cD875FbA9cf34eacde8Ac4cEe) |
| `PoolSwapTest`    | [`0x6e5B4fa1767AA4b8245e590cC2ba469FA471Ba6e`](https://www.oklink.com/xlayer-test/address/0x6e5B4fa1767AA4b8245e590cC2ba469FA471Ba6e) |

**Hook address bits** — `0x…0044` ⇒ low 14 bits `0x44` = `AFTER_SWAP` + `AFTER_SWAP_RETURNS_DELTA`.

**Pool key** — `(currency0, currency1, fee=3000, tickSpacing=60, hooks=GambitFiHook)`,
initialized at price 1:1. Deploy tx also seeded liquidity in `[-600, 600]` and ran one demo
swap (`swapNonce` = 1 on-chain, ~1% lottery fee accrued to the prize pool).

---

## Randomness — honest disclosure

The MVP uses `keccak256(prevrandao, timestamp, blockNumber, player, poolId, nonce) % winChance`.
On an L2 like X Layer this is *good enough for a hackathon demo* but is **not** sufficient
for production-scale prize pools:

- `prevrandao` is influenceable by the sequencer in many L2 designs.
- A motivated MEV searcher can simulate before submitting if the pool gets large.

**Production upgrade path** (documented for the reviewers):

1. **Chainlink VRF on X Layer** — `requestRandomWords` in `afterSwap`, settle prizes
   asynchronously in the VRF callback. Trade-off: prize payout is delayed by ~30s.
2. **Commit-reveal lottery rounds** — players commit during a round, reveal in the next
   round; prize is paid out at the round boundary. Better UX, slightly more on-chain state.
3. **TEE-signed randomness via OKX OnchainOS** — fits the X Layer ecosystem and avoids the
   VRF latency.

The hook's interface stays identical across these upgrades; only the internal `roll`
computation changes.

---

## Future work

- **VRF integration** (above).
- **NFT tickets** — issue an ERC-1155 ticket per qualifying swap, redeemable for prize
  pool share. Opens up secondary markets on ticket positions.
- **Tiered prize structure** — top-3 winners per epoch instead of winner-take-all, to
  smooth the long-tail distribution.
- **Cross-pool jackpot** — share a fraction of every pool's lottery fee into a global
  jackpot drawn weekly. Network effect.

---

## Hackathon submission checklist

- [x] Built on **Uniswap V4 Hook** mechanism with novel logic.
- [x] Deployable to **X Layer mainnet or testnet** — script provided.
- [x] **Verifiable contract address** — populated post-deploy in this README.
- [ ] Dedicated Twitter account tagging `@XLayerOfficial @Uniswap @flapdotsh` — to be set
      up before submission.
- [x] Submission via Google Form before **2026-05-28 23:59 UTC**.

---

## Acknowledgments

- [Uniswap v4-core](https://github.com/Uniswap/v4-core) — the Hook architecture and test
  routers.
- [OKX X Layer](https://web3.okx.com/build/dev-docs/xlayer-network) — host chain.

## License

MIT
