// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./Structs.sol";
import {console} from "forge-std/console.sol";

contract CowOrderMinHeap {
    using Structs for Structs.CowOrder;

    Structs.CowOrder[] public heap;
    bool public init = false;

    // Helper function to get the index of the parent node i.e parent of element 1 and 2 is 0
    function parent(uint256 i) private pure returns (uint256) {
        return (i - 1) / 2;
    }
    
    // Helper function to get the index of the left child node i.e (of 1 => 3)
    function left(uint256 i) private pure returns (uint256) {
        return 2 * i + 1;
    }
    
    // Helper function to get the index of the right child node i.e (of 1 => 4)
    function right(uint256 i) private pure returns (uint256) {
        return 2 * i + 2;
    }
    
    // Helper function to swap two elements in the heap
    function swap(uint256 i, uint256 j) private {
        Structs.CowOrder memory temp = heap[i];
        heap[i] = heap[j];
        heap[j] = temp;
    }
    
    // Function to insert an element into the heap
    function insert(Structs.CowOrder memory order) public {
        heap.push(order);
        uint256 index = heap.length - 1;
        // move up the tree if parent bigger than child
        while (index > 0 && heap[parent(index)].deadline > heap[index].deadline) {
            swap(parent(index), index);
            index = parent(index);
        }
    }
    
    // Function to get the minimum element (root of the heap)
    function getMin() public view returns (Structs.CowOrder memory) {
        require(heap.length > 0, "Heap is empty");
        return heap[0];
    }
    
    // Function to extract the minimum element from the heap
    function extractMin() public returns (Structs.CowOrder memory) {
        require(heap.length > 0, "Heap is empty");
        return removeAt(0);
    }

    function removeAt(uint256 index) public returns (Structs.CowOrder memory) {
        require(index < heap.length, "Index out of bounds");

        Structs.CowOrder memory removedOrder = heap[index];
        
        // Replace the removed element with the last element
        heap[index] = heap[heap.length - 1];
        heap.pop();
        // If we didn't remove the last element, we need to adjust the heap
        if (index < heap.length) {
            // Try moving the element down the heap
            heapify(index);
        }
        return removedOrder;
    }
    
    // Function to maintain the heap property
    function heapify(uint256 index) private {
        uint256 smallest = index;
        uint256 l = left(index);
        uint256 r = right(index);
        
        if (l < heap.length && heap[l].deadline < heap[smallest].deadline) {
            smallest = l;
        }
        
        if (r < heap.length && heap[r].deadline < heap[smallest].deadline) {
            smallest = r;
        }
        
        if (smallest != index) {
            swap(index, smallest);
            heapify(smallest);
        }
    }

    function length() public returns (uint256) {
        return heap.length;
    }

    function getOrder(uint256 index) public returns (Structs.CowOrder memory) {
        require(index < heap.length, "Index out of bounds");
        return heap[index];
    }

    function fullfillOrder(uint256 index, int256 amountFullfilled) public {
        heap[index].orderAmount -= amountFullfilled;
    }
}