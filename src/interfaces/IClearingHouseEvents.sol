// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IClearingHouseEvents
/// @notice Events interface for the ClearingHouse contract
interface IClearingHouseEvents {
    /// @notice Emitted when an order is executed
    /// @param maker Address of the maker order owner
    /// @param taker Address of the taker order owner
    /// @param makerOrderHash Hash of the maker order
    /// @param takerOrderHash Hash of the taker order
    /// @param baseQuantity Amount of base tokens traded
    /// @param quoteQuantity Amount of quote tokens traded
    /// @param takerSide Side of the taker order
    event OrderExecuted(
        address indexed maker,
        address indexed taker,
        bytes32 makerOrderHash,
        bytes32 takerOrderHash,
        uint256 baseQuantity,
        uint256 quoteQuantity,
        uint8 takerSide
    );

    /// @notice Emitted when an order is cancelled
    /// @param maker Address that cancelled the order
    /// @param orderHash Hash of the cancelled order
    event OrderCancelled(address indexed maker, bytes32 orderHash);
}
