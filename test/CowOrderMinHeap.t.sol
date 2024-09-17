// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/CowOrderMinHeap.sol";
import "../src/Structs.sol";

contract CowOrderMinHeapTest is Test {
    CowOrderMinHeap public heap;

    function setUp() public {
        heap = new CowOrderMinHeap();
    }

    function testInsert() public {
        Structs.CowOrder memory order1 = Structs.CowOrder(address(1), 100, 10, 1000);
        Structs.CowOrder memory order2 = Structs.CowOrder(address(2), 200, 20, 500);

        heap.insert(order1);
        heap.insert(order2);

        assertEq(heap.length(), 2);
    }

    function testExtractMin() public {
        Structs.CowOrder memory order1 = Structs.CowOrder(address(1), 100, 10, 1000);
        Structs.CowOrder memory order2 = Structs.CowOrder(address(2), 200, 20, 500);
        Structs.CowOrder memory order3 = Structs.CowOrder(address(3), 300, 30, 1500);

        heap.insert(order1);
        heap.insert(order2);
        heap.insert(order3);

        Structs.CowOrder memory min = heap.extractMin();
        assertEq(min.user, address(2));
        assertEq(min.deadline, 500);
        assertEq(heap.length(), 2);

        min = heap.extractMin();
        assertEq(min.user, address(1));
        assertEq(min.deadline, 1000);
        assertEq(heap.length(), 1);
    }

    function testRemoveAt() public {
        Structs.CowOrder memory order1 = Structs.CowOrder(address(1), 100, 10, 1000);
        Structs.CowOrder memory order2 = Structs.CowOrder(address(2), 200, 20, 500);
        Structs.CowOrder memory order3 = Structs.CowOrder(address(3), 300, 30, 1500);

        heap.insert(order1);
        heap.insert(order2);
        heap.insert(order3);

        Structs.CowOrder memory removed = heap.removeAt(1);
        assertEq(removed.user, address(1));
        assertEq(removed.deadline, 1000);
        assertEq(heap.length(), 2);

        Structs.CowOrder memory min = heap.extractMin();
        assertEq(min.user, address(2));
        assertEq(min.deadline, 500);
    }

    function testHeapProperty() public {
        Structs.CowOrder memory order1 = Structs.CowOrder(address(1), 100, 10, 1000);
        Structs.CowOrder memory order2 = Structs.CowOrder(address(2), 200, 20, 500);
        Structs.CowOrder memory order3 = Structs.CowOrder(address(3), 300, 30, 1500);
        Structs.CowOrder memory order4 = Structs.CowOrder(address(4), 400, 40, 750);

        heap.insert(order1);
        heap.insert(order2);
        heap.insert(order3);
        heap.insert(order4);

        uint256[] memory expectedOrder = new uint256[](4);
        expectedOrder[0] = 500;
        expectedOrder[1] = 750;
        expectedOrder[2] = 1000;
        expectedOrder[3] = 1500;

        for (uint i = 0; i < 4; i++) {
            Structs.CowOrder memory min = heap.extractMin();
            assertEq(min.deadline, expectedOrder[i]);
        }

        assertEq(heap.length(), 0);
    }
}
