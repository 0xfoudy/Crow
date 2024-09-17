// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Structs {
    struct CowOrder {
        address user;
        int256 orderAmount;
        int24 minimumTick;
        uint256 deadline;
    }
}