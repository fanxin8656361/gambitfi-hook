// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {GambitFiHook} from "../src/GambitFiHook.sol";

contract GambitFiHookTest is Test, Deployers {
    GambitFiHook hook;
    PoolKey poolKey;
    PoolId poolId;

    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
    }

    /// @dev Deploys the hook at a flag-encoded address using `deployCodeTo` so the
    ///      address-validation in BaseHook's constructor passes.
    function _deployHook(uint256 winChance, uint256 feeBps, uint256 minSwap) internal {
        address hookAddr = address(FLAGS);
        deployCodeTo(
            "GambitFiHook.sol:GambitFiHook",
            abi.encode(manager, winChance, feeBps, minSwap),
            hookAddr
        );
        hook = GambitFiHook(payable(hookAddr));

        (poolKey, poolId) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
    }

    /// ------------------------------------------------------------
    /// Permissions wiring
    /// ------------------------------------------------------------

    function test_permissions_areAfterSwapOnly() public {
        _deployHook({winChance: 1_000_000, feeBps: 100, minSwap: 0});
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterSwap, "afterSwap on");
        assertTrue(p.afterSwapReturnDelta, "afterSwapReturnDelta on");
        assertFalse(p.beforeSwap, "beforeSwap off");
        assertFalse(p.beforeAddLiquidity, "beforeAddLiquidity off");
    }

    /// ------------------------------------------------------------
    /// Fee accumulation (no-win path: very low win chance)
    /// ------------------------------------------------------------

    function test_swap_feeAccumulatesInPrizePool() public {
        // winChance = 1e9 => effectively never wins, so we observe pure accumulation
        _deployHook({winChance: 1_000_000_000, feeBps: 100, minSwap: 0});

        uint256 amountIn = 1e18;
        BalanceDelta delta = swap(poolKey, true, -int256(amountIn), ZERO_BYTES);

        // Output is on currency1 (zeroForOne, exactInput → unspecified = output = currency1)
        uint256 outputAmount = uint256(int256(delta.amount1()));
        // The hook took 1% fee → user receives 99%, hook now holds 1%
        // Total pool output before fee = output / 0.99 (since user got 99%)
        // Simpler: just assert the hook holds positive and prizePool tracks.
        uint256 prize = hook.prizePool(poolId, currency1);
        assertGt(prize, 0, "prize should accumulate");

        // hook's actual ERC20 balance equals prize pool
        uint256 hookBal1 = currency1.balanceOf(address(hook));
        assertEq(hookBal1, prize, "hook balance == prize pool");

        // sanity: prize is roughly 1% of output
        assertApproxEqRel(prize * 100, outputAmount + prize, 0.01e18, "fee ~1%");

        assertEq(hook.totalTickets(poolId), 1, "1 ticket");
    }

    function test_swap_multipleSwapsCompoundPrizePool() public {
        _deployHook({winChance: 1_000_000_000, feeBps: 100, minSwap: 0});

        for (uint256 i = 0; i < 5; i++) {
            swap(poolKey, i % 2 == 0, -int256(1e17), ZERO_BYTES);
        }

        assertEq(hook.totalTickets(poolId), 5, "5 tickets");
        // some prize must have accumulated on at least one side
        uint256 p0 = hook.prizePool(poolId, currency0);
        uint256 p1 = hook.prizePool(poolId, currency1);
        assertGt(p0 + p1, 0, "some prize");
    }

    /// ------------------------------------------------------------
    /// Min swap threshold
    /// ------------------------------------------------------------

    function test_swap_belowMinSwap_skipsLottery() public {
        // min swap = 1e18 — our 1e6 swap won't qualify
        _deployHook({winChance: 100, feeBps: 100, minSwap: 1e18});

        swap(poolKey, true, -int256(1e6), ZERO_BYTES);

        assertEq(hook.totalTickets(poolId), 0, "no ticket");
        assertEq(hook.prizePool(poolId, currency0), 0, "no prize 0");
        assertEq(hook.prizePool(poolId, currency1), 0, "no prize 1");
    }

    /// ------------------------------------------------------------
    /// Lottery win path (winChance = 1 → always wins)
    /// ------------------------------------------------------------

    function test_swap_winChanceOne_alwaysWinsAndDrainsPrize() public {
        _deployHook({winChance: 1, feeBps: 100, minSwap: 0});

        // before swap
        uint256 testerBal1Before = currency1.balanceOf(address(this));

        // perform a swap via the test swapRouter — sender for hook is the router,
        // and player resolves to that router (sender) since hookData is empty.
        // The lottery payout therefore goes to the router. We assert by checking
        // (a) prize pool was zeroed, (b) hook holds zero balance afterwards,
        // (c) total tickets increased.
        swap(poolKey, true, -int256(1e18), ZERO_BYTES);

        assertEq(hook.prizePool(poolId, currency1), 0, "prize swept");
        assertEq(currency1.balanceOf(address(hook)), 0, "hook drained");
        assertEq(hook.totalTickets(poolId), 1, "ticket counted");

        // tester balance change is not directly asserted because payout goes to swapRouter;
        // confirming hook drained + ticket recorded is sufficient for the win path.
        testerBal1Before; // silence unused
    }

    /// ------------------------------------------------------------
    /// hookData recipient override
    /// ------------------------------------------------------------

    function test_swap_hookDataOverridesRecipient_winnerGetsPaid() public {
        _deployHook({winChance: 1, feeBps: 100, minSwap: 0});

        address recipient = makeAddr("lucky-player");
        uint256 recipientBalBefore = currency1.balanceOf(recipient);

        bytes memory data = abi.encode(recipient);
        swap(poolKey, true, -int256(1e18), data);

        uint256 recipientBalAfter = currency1.balanceOf(recipient);
        assertGt(recipientBalAfter, recipientBalBefore, "recipient was paid");
        assertEq(hook.prizePool(poolId, currency1), 0, "prize swept");
    }

    /// ------------------------------------------------------------
    /// Constructor validation
    /// ------------------------------------------------------------

    function test_constructor_revertsOnZeroWinChance() public {
        address hookAddr = address(FLAGS);
        vm.expectRevert();
        deployCodeTo(
            "GambitFiHook.sol:GambitFiHook",
            abi.encode(manager, uint256(0), uint256(100), uint256(0)),
            hookAddr
        );
    }

    function test_constructor_revertsOnFeeBpsTooHigh() public {
        address hookAddr = address(FLAGS);
        vm.expectRevert();
        deployCodeTo(
            "GambitFiHook.sol:GambitFiHook",
            abi.encode(manager, uint256(100), uint256(2000), uint256(0)),
            hookAddr
        );
    }
}
