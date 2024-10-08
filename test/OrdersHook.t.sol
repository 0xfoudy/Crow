// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

// Foundry libraries
import {Test, console} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";


// Our contracts
import {OrdersHook} from "../src/OrdersHook.sol";
import "../src/Structs.sol";
import "../src/CowOrderMinHeap.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OrdersHookTest is Test, Deployers {
    // Use the libraries
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    OrdersHook hook;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy our hook
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);
        deployCodeTo(
            "OrdersHook.sol",
            abi.encode(manager, ""),
            hookAddress
        );
        hook = OrdersHook(hookAddress);

        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(hook),
            type(uint256).max
        );

        // Initialize a pool with these two tokens
        (key, ) = initPool(
            token0,
            token1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add initial liquidity to the pool

        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function test_placeOrder() public {
        // Place a zeroForOne take-profit order
        // for 10e18 token0 tokens
        // at tick 100
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();

        // Place the order
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        // Note the new balance of token0 we have
        uint256 newBalance = token0.balanceOfSelf();

        // Since we deployed the pool contract with tick spacing = 60
        // i.e. the tick can only be a multiple of 60
        // the tickLower should be 60 since we placed an order at tick 100
        assertEq(tickLower, 60);

        // Ensure that our balance of token0 was reduced by `amount` tokens
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(positionId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        // Place an order as earlier
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOfSelf();
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);
        uint256 newBalance = token0.balanceOfSelf();

        assertEq(tickLower, 60);
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, amount);

        // Cancel the order
        hook.cancelOrder(key, tickLower, zeroForOne);

        // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
        uint256 finalBalance = token0.balanceOfSelf();
        assertEq(finalBalance, originalBalance);

        tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 0);
    }

    function test_orderExecute_zeroForOne() public {
        int24 tick = 100;
        uint256 amount = 1 ether;
        bool zeroForOne = true;

        // Place our order at tick 100 for 10e18 token0 tokens
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Conduct the swap - `afterSwap` should also execute our placed order
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Check that the order has been executed
        // by ensuring no amount is left to sell in the pending orders
        uint256 pendingTokensForPosition = hook.pendingOrders(
            key.toId(),
            tick,
            zeroForOne
        );
        assertEq(pendingTokensForPosition, 0);

        // Check that the hook contract has the expected number of token1 tokens ready to redeem
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        assertEq(claimableOutputTokens, hookContractToken1Balance);

        // Ensure we can redeem the token1 tokens
        uint256 originalToken1Balance = token1.balanceOf(address(this));
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken1Balance = token1.balanceOf(address(this));

        assertEq(
            newToken1Balance - originalToken1Balance,
            claimableOutputTokens
        );
    }

    function test_orderExecute_oneForZero() public {
        int24 tick = -100;
        uint256 amount = 10 ether;
        bool zeroForOne = false;

        // Place our order at tick -100 for 10e18 token1 tokens
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        // Do a separate swap from zeroForOne to make tick go down
        // Sell 1e18 token0 tokens for token1 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Check that the order has been executed
        uint256 tokensLeftToSell = hook.pendingOrders(
            key.toId(),
            tick,
            zeroForOne
        );
        assertEq(tokensLeftToSell, 0);

        // Check that the hook contract has the expected number of token0 tokens ready to redeem
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        uint256 hookContractToken0Balance = token0.balanceOf(address(hook));
        assertEq(claimableOutputTokens, hookContractToken0Balance);

        // Ensure we can redeem the token0 tokens
        uint256 originalToken0Balance = token0.balanceOfSelf();
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken0Balance = token0.balanceOfSelf();

        assertEq(
            newToken0Balance - originalToken0Balance,
            claimableOutputTokens
        );
    }

    function test_multiple_orderExecute_zeroForOne_onlyOne() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Setup two zeroForOne orders at ticks 0 and 60
        uint256 amount = 0.01 ether;

        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);

        (, int24 currentTick, , ) = manager.getSlot0(key.toId());
        assertEq(currentTick, 0);

        // Do a swap to make tick increase beyond 60
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Only one order should have been executed
        // because the execution of that order would lower the tick
        // so even though tick increased beyond 60
        // the first order execution will lower it back down
        // so order at tick = 60 will not be executed
        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), 0, true);
        assertEq(tokensLeftToSell, 0);

        // Order at Tick 60 should still be pending
        tokensLeftToSell = hook.pendingOrders(key.toId(), 60, true);
        assertEq(tokensLeftToSell, amount);
    }

    function test_multiple_orderExecute_zeroForOne_both() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Setup two zeroForOne orders at ticks 0 and 60
        uint256 amount = 0.01 ether;

        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);

        // Do a swap to make tick increase
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), 0, true);
        assertEq(tokensLeftToSell, 0);

        tokensLeftToSell = hook.pendingOrders(key.toId(), 60, true);
        assertEq(tokensLeftToSell, 0);
    }


    function test_createCowSwap() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Perform a zeroToOne swap for 10e18 token0 tokens at tick 100, with a deadline of 10 blocks
        bool zeroForOne = true;
        uint256 deadline = 10;
        int24 tick = 100;

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();
        uint256 hookBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        // Do a the swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -10 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data = abi.encode(address(this), deadline, tick);
        

       
        swapRouter.swap(key, params, testSettings, data);
        assertEq(originalBalance - token0.balanceOfSelf(), 10e18);
        assertEq(MockERC20(Currency.unwrap(token0)).balanceOf(address(hook)) - hookBalance, 10e18);
    }


    function test_matchCowAtCurrentTick() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Perform a zeroToOne swap for 10e18 token0 tokens at tick 100, with a deadline of 10 blocks
        bool zeroForOne = true;
        uint256 deadline = 10;
        int24 tick = 0;

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();
        uint256 originalBalance1 = token1.balanceOfSelf();
        uint256 hookBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        // Do a the swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -10 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data = abi.encode(address(this), deadline, tick);
        
        IPoolManager.SwapParams memory reverseParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -10 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, testSettings, data);
        Structs.CowOrder memory order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 10e18);

        swapRouter.swap(key, reverseParams, testSettings, data);
        order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 0);

        uint256 inverseOrderLength = hook.getCowOrders(key.toId(), key.currency1, key.currency0).length();
        // make sure other order wasn't done cause it was fully fullfilled
        assertEq(inverseOrderLength, 0);

        assertEq(originalBalance - token0.balanceOfSelf(), 10 ether);
        assertEq(originalBalance1 - token1.balanceOfSelf(), 10 ether * 15/10000); // make sure the fee was taken after all is 'returned' (fullfilled self order)
        assertEq(MockERC20(Currency.unwrap(token0)).balanceOf(address(hook)) - hookBalance, 0);
    }

    function test_halfMatchCowAtCurrentTick() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Perform a zeroToOne swap for 10e18 token0 tokens at tick 100, with a deadline of 10 blocks
        bool zeroForOne = true;
        uint256 deadline = 10;
        int24 tick = 0;

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();
        uint256 hookBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        // Do a the swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -10 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data = abi.encode(address(this), deadline, tick);
        
        IPoolManager.SwapParams memory reverseParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, testSettings, data);
        Structs.CowOrder memory order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 10e18);

        swapRouter.swap(key, reverseParams, testSettings, data);
        order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 5e18);

        uint256 inverseOrderLength = hook.getCowOrders(key.toId(), key.currency1, key.currency0).length();
        // make sure other order wasn't done cause it was fully fullfilled
        assertEq(inverseOrderLength, 0);
    }

    function test_overMatchCowAtCurrentTick() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Perform a zeroToOne swap for 10e18 token0 tokens at tick 100, with a deadline of 10 blocks
        bool zeroForOne = true;
        uint256 deadline = 10;
        int24 tick = 0;

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();
        uint256 hookBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        // Do a the swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -3 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data = abi.encode(address(this), deadline, tick);
        
        IPoolManager.SwapParams memory reverseParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, testSettings, data);
        Structs.CowOrder memory order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 3e18);
        swapRouter.swap(key, reverseParams, testSettings, data);
        order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 0);

        order = hook.getCowOrders(key.toId(), key.currency1, key.currency0).getOrder(0);
        assertEq(order.orderAmount, 2e18);
    }

    function test_matchExactCowAtHigherTick() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Perform a zeroToOne swap for 10e18 token0 tokens at tick 100, with a deadline of 10 blocks
        bool zeroForOne = true;
        uint256 deadline = 10;
        int24 tick = 100;

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();
        uint256 hookBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        // Do a the swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -3 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data = abi.encode(address(this), deadline, tick);
        

        swapRouter.swap(key, params, testSettings, data);
        Structs.CowOrder memory order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 3e18);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        // Conduct the swap - `afterSwap` should also execute our placed order
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);


        // Last swap to match Cow
        IPoolManager.SwapParams memory reverseParams = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(key, reverseParams, testSettings, ZERO_BYTES);
        order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 0);
    }

    function test_matchExactCowAtLowerTick() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Perform a zeroToOne swap for 10e18 token0 tokens at tick 100, with a deadline of 10 blocks
        bool zeroForOne = true;
        uint256 deadline = 10;
        int24 tick = 100;

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();
        uint256 hookBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        // Do a the swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -3 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data = abi.encode(address(this), deadline, tick);
        

        swapRouter.swap(key, params, testSettings, data);
        Structs.CowOrder memory order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 3e18);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        // Conduct the swap - `afterSwap` should also execute our placed order
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);


        // Last swap to match Cow
        IPoolManager.SwapParams memory reverseParams = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(key, reverseParams, testSettings, ZERO_BYTES);
        order = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        assertEq(order.orderAmount, 0);
    }

    function test_removeCowOrder() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        bool zeroForOne = true;
        uint256 deadline = 10;
        int24 tick = 0;

        // Note the original balances
        uint256 originalBalance0 = token0.balanceOfSelf();
        uint256 originalBalance1 = token1.balanceOfSelf();

        // Create two orders
        IPoolManager.SwapParams memory params1 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data1 = abi.encode(address(this), deadline, tick);

        IPoolManager.SwapParams memory params2 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -3 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data2 = abi.encode(address(this), deadline+1, tick);

        // Place the orders
        swapRouter.swap(key, params1, testSettings, data1);
        swapRouter.swap(key, params2, testSettings, data2);

        // Check that both orders are in place
        Structs.CowOrder memory order1 = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(0);
        Structs.CowOrder memory order2 = hook.getCowOrders(key.toId(), key.currency0, key.currency1).getOrder(1);
        assertEq(order1.orderAmount, 5 ether);
        assertEq(order2.orderAmount, 3 ether);

        // Remove the first order
        hook.cancelCowOrder(key, key.currency0, key.currency1);

        // Check that only the second order remains
        CowOrderMinHeap ordersHeap = hook.getCowOrders(key.toId(), key.currency0, key.currency1);
        order1 = ordersHeap.getOrder(0);
        assertEq(order1.orderAmount, 3 ether);

        // Try to get the second order (should revert as there's only one order now)
        vm.expectRevert();
        ordersHeap.getOrder(1);

        // Check that the balance of token0 has been returned for the removed order
        uint256 newBalance0 = token0.balanceOfSelf();
        assertEq(newBalance0, originalBalance0 - 3 ether);

        // Check that the balance of token1 hasn't changed
        uint256 newBalance1 = token1.balanceOfSelf();
        assertEq(newBalance1, originalBalance1);
    }

    function test_fulfillExpiredOrder() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        bool zeroForOne = true;
        uint256 deadline = block.timestamp + 10;
        int24 tick = 0;

        // Create two orders for the same user (this contract)
        IPoolManager.SwapParams memory params1 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data1 = abi.encode(address(this), deadline, tick);

        IPoolManager.SwapParams memory params2 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -3 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data2 = abi.encode(address(this), deadline + 5, tick - 8000);

        // Place the orders
        swapRouter.swap(key, params1, testSettings, data1);
        swapRouter.swap(key, params2, testSettings, data2);

        // Check that both orders are in place
        assertEq(hook.getCowOrders(key.toId(), key.currency0, key.currency1).length(), 2);

        // Try to fulfill the order before it expires (should revert)
        vm.expectRevert("No expired order found for the user");
        hook.fulfillExpiredOrder(key, key.currency0, key.currency1);

        // Advance time past the first deadline but before the second
        vm.warp(block.timestamp +deadline + 1);

        // Note the original balances
        uint256 originalBalance0 = token0.balanceOfSelf();
        uint256 originalBalance1 = token1.balanceOfSelf();

        // Fulfill the expired order
        hook.fulfillExpiredOrder(key, key.currency0, key.currency1);

        // Check that only one order remains
        assertEq(hook.getCowOrders(key.toId(), key.currency0, key.currency1).length(), 1);

        // Check that the balances have changed appropriately
        uint256 newBalance0 = token0.balanceOfSelf();
        uint256 newBalance1 = token1.balanceOfSelf();
        assertEq(newBalance0, originalBalance0);
        assertGt(newBalance1, originalBalance1);  // We should have more of token1

        // Advance time past the second deadline
        vm.warp(deadline + 6);

        // Fulfill the second expired order
        hook.fulfillExpiredOrder(key, key.currency0, key.currency1);

        // Check that no orders remain
        assertEq(hook.getCowOrders(key.toId(), key.currency0, key.currency1).length(), 0);

        // Try to fulfill a non-existent order (should revert)
        vm.expectRevert("No orders to fulfill");
        hook.fulfillExpiredOrder(key, key.currency0, key.currency1);
    }

    function test_fulfillExpiredOrders() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        bool zeroForOne = true;
        uint256 baseDeadline = block.timestamp + 10;
        int24 tick = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory data = abi.encode(address(this), baseDeadline, tick);
        swapRouter.swap(key, params, testSettings, data);

        bytes memory data2 = abi.encode(address(this), baseDeadline + 5, tick-2000);
        swapRouter.swap(key, params, testSettings, data2);

        bytes memory data3 = abi.encode(address(this), baseDeadline + 10, tick-4000);
        swapRouter.swap(key, params, testSettings, data3);

        // Check that all orders are in place
        assertEq(hook.getCowOrders(key.toId(), key.currency0, key.currency1).length(), 3);

        // Try to fulfill orders before they expire (should revert)
        vm.expectRevert("No fulfillable orders found");
        hook.fulfillExpiredOrders(key, key.currency0, key.currency1, 3);

        // Advance time past all deadlines
        vm.warp(baseDeadline + 15);

        // Note the original balances
        uint256[] memory originalBalances0 = new uint256[](3);
        uint256[] memory originalBalances1 = new uint256[](3);
        for (uint i = 0; i < 3; i++) {
            originalBalances0[i] = token0.balanceOf(address(this));
            originalBalances1[i] = token1.balanceOf(address(this));
        }

        // Fulfill the expired orders (2 out of 3)
        hook.fulfillExpiredOrders(key, key.currency0, key.currency1, 2);

        // Check that only one order remains
        assertEq(hook.getCowOrders(key.toId(), key.currency0, key.currency1).length(), 1);

        // Check that the balances have changed appropriately for the first two users
        for (uint i = 0; i < 2; i++) {
            uint256 newBalance0 = token0.balanceOf(address(this));
            uint256 newBalance1 = token1.balanceOf(address(this));
            assertEq(newBalance0, originalBalances0[i]);
            assertGt(newBalance1, originalBalances1[i]);
        }

        // Fulfill the remaining order 
        hook.fulfillExpiredOrders(key, key.currency0, key.currency1, 1);

        // Check that no orders remain
        assertEq(hook.getCowOrders(key.toId(), key.currency0, key.currency1).length(), 0);

        // Check the balance of the last user
        uint256 newBalance0 = token0.balanceOf(address(this));
        uint256 newBalance1 = token1.balanceOf(address(this));
        assertEq(newBalance0, originalBalances0[2]);
        assertGt(newBalance1, originalBalances1[2]);

        // Try to fulfill orders when no orders exist (should revert)
        vm.expectRevert("No orders to fulfill");
        hook.fulfillExpiredOrders(key, key.currency0, key.currency1, 1);
    }

}