// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {BaseHook} from "./base/BaseHook.sol";

/// @title GambitFiHook — every swap is a scratch ticket.
/// @notice On each qualifying swap, the hook charges a small lottery fee on the unspecified
///         token. Fees accumulate in a per-pool prize pool. A pseudo-random roll decides if
///         the swap wins; the winner sweeps the prize pool for that token.
///
///         Randomness uses `block.prevrandao + tx context + monotonic nonce`. This is good
///         enough for an L2 testnet hackathon demo, but production deployments should swap
///         in Chainlink VRF or a commit-reveal scheme. See README "Randomness" section.
contract GambitFiHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    /// ---------- config ----------

    /// @notice 1 in `winChance` swaps wins. e.g. 100 = 1% per qualifying swap.
    uint256 public immutable winChance;

    /// @notice Lottery fee charged on the unspecified token, in basis points (1/10000).
    uint256 public immutable lotteryFeeBps;

    /// @notice Minimum unspecified swap amount required to qualify. Filters dust spam.
    uint256 public immutable minSwapAmount;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @dev Hard cap on lotteryFeeBps at construction to prevent absurd config (10%).
    uint256 public constant MAX_FEE_BPS = 1_000;

    /// ---------- state ----------

    /// @notice prize pool balance per (poolId, currency).
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) public prizePool;

    /// @notice Total tickets issued per pool — useful for analytics / leaderboards.
    mapping(PoolId poolId => uint256 count) public totalTickets;

    /// @notice Monotonic nonce mixed into randomness. Increments per qualifying swap.
    uint256 public swapNonce;

    /// ---------- events ----------

    event TicketIssued(
        PoolId indexed poolId,
        address indexed player,
        Currency currency,
        uint256 feeAmount,
        uint256 newPrizePool,
        uint256 nonce
    );

    event LotteryWin(
        PoolId indexed poolId,
        address indexed winner,
        Currency currency,
        uint256 prize,
        uint256 nonce
    );

    /// ---------- errors ----------

    error WinChanceZero();
    error FeeBpsOutOfRange();

    constructor(IPoolManager _poolManager, uint256 _winChance, uint256 _lotteryFeeBps, uint256 _minSwapAmount)
        BaseHook(_poolManager)
    {
        if (_winChance == 0) revert WinChanceZero();
        if (_lotteryFeeBps == 0 || _lotteryFeeBps > MAX_FEE_BPS) revert FeeBpsOutOfRange();
        winChance = _winChance;
        lotteryFeeBps = _lotteryFeeBps;
        minSwapAmount = _minSwapAmount;
    }

    /// ---------- hook permissions ----------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// ---------- core logic ----------

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Determine unspecified currency + its absolute amount.
        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency unspecifiedCurrency, int128 unspecifiedDelta) =
            specifiedTokenIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (unspecifiedDelta < 0) unspecifiedDelta = -unspecifiedDelta;
        // forge-lint: disable-next-line(unsafe-typecast)
        // unspecifiedDelta is non-negative int128 after the flip above; fits in uint128.
        uint256 absAmount = uint128(unspecifiedDelta);

        // Skip dust swaps entirely — no ticket, no fee.
        if (absAmount < minSwapAmount) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        uint256 feeAmount = (absAmount * lotteryFeeBps) / BPS_DENOMINATOR;
        if (feeAmount == 0) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        // Pull fee out of the pool into the hook's own balance.
        poolManager.take(unspecifiedCurrency, address(this), feeAmount);

        PoolId pid = key.toId();
        uint256 newPool = prizePool[pid][unspecifiedCurrency] + feeAmount;
        prizePool[pid][unspecifiedCurrency] = newPool;
        totalTickets[pid] += 1;

        // Recipient resolution: hookData == abi.encode(address) overrides; else swap caller.
        address player = sender;
        if (hookData.length == 32) {
            player = abi.decode(hookData, (address));
        }

        uint256 nonce = ++swapNonce;
        emit TicketIssued(pid, player, unspecifiedCurrency, feeAmount, newPool, nonce);

        // Roll the dice.
        uint256 roll = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    block.timestamp,
                    block.number,
                    player,
                    PoolId.unwrap(pid),
                    nonce
                )
            )
        ) % winChance;

        if (roll == 0) {
            uint256 prize = newPool;
            prizePool[pid][unspecifiedCurrency] = 0;
            unspecifiedCurrency.transfer(player, prize);
            emit LotteryWin(pid, player, unspecifiedCurrency, prize, nonce);
        }

        return (IHooks.afterSwap.selector, feeAmount.toInt128());
    }

    /// @notice Allow the hook to receive native gas token (so prize payouts in native work).
    receive() external payable {}
}
