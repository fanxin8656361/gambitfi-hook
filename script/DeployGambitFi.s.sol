// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {GambitFiHook} from "../src/GambitFiHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {Create2Deployer} from "./utils/Create2Deployer.sol";
import {DemoERC20} from "./utils/DemoERC20.sol";

/// @notice End-to-end deploy: factory → PoolManager → demo tokens → hook → pool → liquidity.
///         Works on a fresh chain (e.g. X Layer testnet) where v4 is not yet deployed.
contract DeployGambitFi is Script {
    // Default lottery config: 1% ticket fee, 1 in 100 wins, 1e15 minimum swap.
    uint256 constant DEFAULT_WIN_CHANCE = 100;
    uint256 constant DEFAULT_FEE_BPS = 100;
    uint256 constant DEFAULT_MIN_SWAP = 1e15;

    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    // sqrt(1) << 96
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        console2.log("deployer", deployer);

        vm.startBroadcast(deployerPk);

        // 1. CREATE2 factory (used to land hook at a flag-encoded address).
        Create2Deployer factory = new Create2Deployer();
        console2.log("Create2Deployer", address(factory));

        // 2. PoolManager (owner = deployer).
        PoolManager manager = new PoolManager(deployer);
        console2.log("PoolManager", address(manager));

        // 3. v4-core test routers for LP + swap (so the demo works without periphery).
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        console2.log("LP router    ", address(lpRouter));
        console2.log("Swap router  ", address(swapRouter));

        // 4. Demo ERC20s, sorted so currency0 < currency1.
        DemoERC20 a = new DemoERC20("GambitFi Demo A", "GDA");
        DemoERC20 b = new DemoERC20("GambitFi Demo B", "GDB");
        (DemoERC20 t0, DemoERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        console2.log("Token0", address(t0));
        console2.log("Token1", address(t1));

        // 5. Mine a CREATE2 salt that lands the hook at a flag-encoded address.
        bytes memory creationCode = type(GambitFiHook).creationCode;
        bytes memory args =
            abi.encode(IPoolManager(address(manager)), DEFAULT_WIN_CHANCE, DEFAULT_FEE_BPS, DEFAULT_MIN_SWAP);
        (address predicted, bytes32 salt) = HookMiner.find(address(factory), FLAGS, creationCode, args);
        console2.log("Hook (predicted)", predicted);

        // 6. Deploy hook through factory using mined salt.
        address actual = factory.deploy(salt, abi.encodePacked(creationCode, args));
        require(actual == predicted, "hook addr mismatch");
        GambitFiHook hook = GambitFiHook(payable(actual));
        console2.log("Hook (deployed) ", address(hook));

        // 7. Build PoolKey and initialize the pool.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        console2.log("Pool initialized");

        // 8. Seed liquidity. Mint via two faucet calls (1k cap each), approve LP router, add LP.
        t0.mint(deployer, DemoERC20(t0).FAUCET_AMOUNT());
        t1.mint(deployer, DemoERC20(t1).FAUCET_AMOUNT());
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        ModifyLiquidityParams memory lp = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 1e20,
            salt: bytes32(0)
        });
        lpRouter.modifyLiquidity(key, lp, bytes(""));
        console2.log("Liquidity added");

        // 9. Demo swap so the first ticket lands on-chain and an event fires.
        SwapParams memory sp = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e17,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap(key, sp, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), bytes(""));
        console2.log("Demo swap done");

        vm.stopBroadcast();

        console2.log("------ DEPLOYMENT SUMMARY ------");
        console2.log("PoolManager     :", address(manager));
        console2.log("Create2Deployer :", address(factory));
        console2.log("GambitFiHook    :", address(hook));
        console2.log("Token0 (GDA/GDB):", address(t0));
        console2.log("Token1 (GDA/GDB):", address(t1));
        console2.log("LP router       :", address(lpRouter));
        console2.log("Swap router     :", address(swapRouter));
    }
}
