# OrdersHook Documentation

## Overview

OrdersHook is a smart contract that extends the functionality of Uniswap v4 by implementing limit orders and Coincidence of Wants (CoW) orders. It allows users to place, cancel, and fulfill orders based on specific price conditions and expiration times.

## Key Features

1. **Limit Orders**: Users can place orders to buy or sell tokens at a specific price.
2. **CoW Orders**: Enables efficient matching of complementary orders without affecting the pool price.
3. **Order Expiration**: Orders automatically expire after a set time, ensuring market relevance.
4. **Order Fulfillment**: Any user can fulfill expired orders, helping to clean up the order book.

## Main Functions

### `placeOrder`
- Places a new limit order or CoW order.
- Parameters: pool key, tick, direction (zeroForOne), amount.
- Returns: the lower tick of the order's price range.

### `cancelOrder`
- Cancels an existing order and returns funds to the user.
- Parameters: pool key, tick, direction (zeroForOne).

### `fulfillExpiredOrders`
- Fulfills multiple expired orders.
- Parameters: pool key, sell token, buy token, maximum number of orders to fulfill.
- Can be called by any user to clean up the order book.

### `deleteCowOrder`
- Removes a specific CoW order placed by the caller.
- Parameters: pool key, sell token, buy token.

## Events

- `OrderPlaced`: Emitted when a new order is placed.
- `OrderCancelled`: Emitted when an order is cancelled.
- `ExpiredOrderFulfilled`: Emitted when an expired order is fulfilled.

## Usage

1. Users interact with OrdersHook through a frontend or directly with the contract.
2. Orders are stored in a min-heap data structure, optimized for efficient processing.
3. The contract integrates with Uniswap v4's hook system, allowing for custom logic during swaps.

## Security Considerations

- Orders are executed only when conditions (price, expiration) are met.
- The contract uses access control to ensure only authorized actions are performed.
- Funds are securely managed within the Uniswap v4 pool until order execution or cancellation.

## Integration

OrdersHook is designed to work seamlessly with Uniswap v4 pools and can be deployed as a hook for any compatible pool.