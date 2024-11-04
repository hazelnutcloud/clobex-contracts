// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IClearingHouseEvents
/// @notice Events interface for the ClearingHouse contract
interface IClearingHouseEvents {
    /// @notice Emitted when an order is executed
    /// @param takerOrderHash Hash of the taker order
    /// @param makerOrderHash Hash of the maker order
    /// @param executionPrice Price at which the trade was executed
    /// @param baseQuantity Amount of base tokens traded
    /// @param quoteQuantity Amount of quote tokens traded
    /// @param maker Maker of the maker order
    /// @param taker Maker of the taker order
    event OrderExecuted(
        bytes32 indexed takerOrderHash,
        bytes32 indexed makerOrderHash,
        uint256 executionPrice,
        uint256 baseQuantity,
        uint256 quoteQuantity,
        address indexed maker,
        address taker
    );

    /// @notice Emitted when an order is cancelled
    /// @param orderHash Hash of the cancelled order
    /// @param maker Address that cancelled the order
    event OrderCancelled(bytes32 indexed orderHash, address indexed maker);
}
