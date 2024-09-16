// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";


import {console} from "forge-std/console.sol";



contract OrdersHook is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    struct CowOrder {
        address user;
        int256 orderAmount;
        int24 minimumTick;
        uint256 timestamp;
    }

    // Storage
    mapping(PoolId poolId => int24 lastTick) public lastTicks;
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public pendingOrders;

    mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;
    mapping(uint256 positionId => uint256 claimsSupply) public claimTokensSupply;

    mapping(PoolId poolId => mapping(Currency token0 => mapping(Currency token1 => CowOrder order))) public cowOrders;

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // Constructor
    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}

    // BaseHook Functions
    function getHookPermissions()
        public pure override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterInitialize(
        address, PoolKey calldata key, uint160, int24 tick, bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }


    // swapper must choose whether the swap is to be immediate or wait for a CoW
    // If wait for a CoW, precise deadline and minimum price

    function beforeSwap(
        address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // (maybe it's a good idea to go into beforeSwap, then fullfilled limit orders could also mathc CoWs)
        //if (sender == address(this)) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Should we try to find and match orders. True initially
        bool tryMore = true;
        int256 remainingTokensToSwap = params.amountSpecified;
        BeforeSwapDelta beforeSwapDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        while (tryMore) {
            // Try executing matching pending orders for this pool

            // `tryMore` is true if we successfully found and fullfilled a CoW and therefore we need to look again if there we can still fullfill another CoW

            // `remainingTokensToSwap` is the amount left after fullfilling an order if no order was executed, `remainingTokensToSwap` will be the same as params.amountSpecified, and `tryMore` will be false
            (tryMore, remainingTokensToSwap) = tryMatchingCows(
                key,
                remainingTokensToSwap,
                !params.zeroForOne
            );
        }

        // check if CoW order or regular order
        if(hookData.length > 0) {
            // this NoOp will only for swap exact input and not exact output swaps
            require(remainingTokensToSwap < 0, "Must have an exact input swap to place CoW order");
            remainingTokensToSwap = - remainingTokensToSwap;
            // decode hookData to get deadline and minimum acceptable price
            (uint256 deadline, int24 minimumTick) = abi.decode(hookData,(uint256,int24));
            // beforeSwapDelta specified amount = negative(amountSpecified) to let it become a NoOp (letting amountToSwap become 0 in Hooks.sol) and unspecified amount to 0
            // change , so that we take the input and swapper gets back nothing in return for the moment
            beforeSwapDelta = toBeforeSwapDelta(int128(remainingTokensToSwap), 0);
            // create CoW order
            // take custody of the input tokens
            CowOrder memory cowOrder = CowOrder(sender, remainingTokensToSwap, minimumTick, block.timestamp + deadline);
            (Currency sellToken, Currency buyToken) = params.zeroForOne 
                ? (key.currency0, key.currency1)
                : (key.currency1, key.currency0);

            cowOrders[key.toId()][sellToken][buyToken] = cowOrder;

            poolManager.take(sellToken, address(this), uint256(remainingTokensToSwap));
        }

        // after our orders are executed
        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    function afterSwap(
        address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta, bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {

        // `sender` is the address which initiated the swap if `sender` is the hook, we don't want to go down the `afterSwap` rabbit hole again
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        // Should we try to find and execute orders? True initially
        bool tryMore = true;
        int24 currentTick;

        while (tryMore) {
            // Try executing pending orders for this pool

            // `tryMore` is true if we successfully found and executed an order which shifted the tick value and therefore we need to look again if there are any pending orders
            // within the new tick range

            // `tickAfterExecutingOrder` is the tick value of the pool after executing an orderif no order was executed, `tickAfterExecutingOrder` will be the same as current tick, and `tryMore` will be false
            (tryMore, currentTick) = tryExecutingOrders(
                key,
                !params.zeroForOne
            );
        }

        // New last known tick for this pool is the tick value after our orders are executed
        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    // Core Hook External Functions
    function placeOrder(
        PoolKey calldata key,int24 tickToSellAt, bool zeroForOne, uint256 inputAmount
    ) public returns (int24) {
        // Get lower actually usable tick given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        // Mint claim tokens to user equal to their `inputAmount`
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");

        // Depending on direction of swap, we select the proper input token and request a transfer of those tokens to the hook contract
        address sellToken = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        // Return the tick at which the order was actually placed
        return tick;
    }

    function cancelOrder(
        PoolKey calldata key, int24 tickToSellAt, bool zeroForOne
    ) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // Check how many claim tokens they have for this position
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens == 0) revert InvalidOrder();

        // Remove their `positionTokens` worth of position from pending orders
        // NOTE: We don't want to zero this out directly because other users may have the same position
        pendingOrders[key.toId()][tick][zeroForOne] -= positionTokens;
        // Reduce claim token total supply and burn their share
        claimTokensSupply[positionId] -= positionTokens;
        _burn(msg.sender, positionId, positionTokens);

        // Send them their input token
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, positionTokens);
    }

    function redeem(
        PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmountToClaimFor
    ) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // If no output tokens can be claimed yet i.e. order hasn't been filled
        // throw error
        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        // they must have claim tokens >= inputAmountToClaimFor
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];

        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForPosition,
            totalInputAmountForPosition
        );

        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        // Transfer output tokens
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    // Internal Functions

    function tryMatchingCows(
        PoolKey calldata key,
        int256 amountOut,
        bool executeZeroForOne
    ) internal returns (bool tryMore, int256 remainingTokensToSwap)
    {
        // Look for match
        remainingTokensToSwap = amountOut;
        if(remainingTokensToSwap == amountOut) return (false, amountOut);
    }

    function tryExecutingOrders(
        PoolKey calldata key,

        bool executeZeroForOne
    ) internal returns (bool tryMore, int24 newTick) {
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];

        // Given `currentTick` and `lastTick`, 2 cases are possible:

        // Case (1) - Tick has increased, i.e. `currentTick > lastTick`
        // or, Case (2) - Tick has decreased, i.e. `currentTick < lastTick`

        // If tick increases => Token 0 price has increased
        // => We should check if we have orders looking to sell Token 0
        // i.e. orders with zeroForOne = true

        // ------------
        // Case (1)
        // ------------

        // Tick has increased i.e. people bought Token 0 by selling Token 1
        // i.e. Token 0 price has increased
        // e.g. in an ETH/USDC pool, people are buying ETH for USDC causing ETH price to increase
        // We should check if we have any orders looking to sell Token 0
        // at ticks `lastTick` to `currentTick`
        // i.e. check if we have any orders to sell ETH at the new price that ETH is at now because of the increase
        if (currentTick > lastTick) {
            // Loop over all ticks from `lastTick` to `currentTick`
            // and execute orders that are looking to sell Token 0
            for (
                int24 tick = lastTick;
                tick < currentTick;
                tick += key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    executeZeroForOne
                ];
                if (inputAmount > 0) {
                    // An order with these parameters can be placed by one or more users
                    // We execute the full order as a single swap
                    // Regardless of how many unique users placed the same order
                    executeOrder(key, tick, executeZeroForOne, inputAmount);

                    // Return true because we may have more orders to execute
                    // from lastTick to new current tick
                    // But we need to iterate again from scratch since our sale of ETH shifted the tick down
                    return (true, currentTick);
                }
            }
        }
        // ------------
        // Case (2)
        // ------------
        // Tick has gone down i.e. people bought Token 1 by selling Token 0
        // i.e. Token 1 price has increased
        // e.g. in an ETH/USDC pool, people are selling ETH for USDC causing ETH price to decrease (and USDC to increase)
        // We should check if we have any orders looking to sell Token 1
        // at ticks `currentTick` to `lastTick`
        // i.e. check if we have any orders to buy ETH at the new price that ETH is at now because of the decrease
        else {
            for (
                int24 tick = lastTick;
                tick > currentTick;
                tick -= key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    executeZeroForOne
                ];
                if (inputAmount > 0) {
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }

        return (false, currentTick);
    }

    function executeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount
    ) internal {
        // Do the actual swap and settle all balances
        BalanceDelta delta = swapAndSettleBalances(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // We provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // `inputAmount` has been deducted from this position
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[positionId] += outputAmount;
    }

    function swapAndSettleBalances(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(key, params, "");

        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }

    // Helper Functions
    function getPositionId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    function getLowerUsableTick(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        // E.g. tickSpacing = 60, tick = -100
        // closest usable tick rounded-down will be -120

        // intervals = -100/60 = -1 (integer division)
        int24 intervals = tick / tickSpacing;

        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity

        // actual usable tick, then, is intervals * tickSpacing
        // i.e. -2 * 60 = -120
        return intervals * tickSpacing;
    }
}