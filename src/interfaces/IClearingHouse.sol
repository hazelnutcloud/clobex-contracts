// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IClearingHouse
/// @notice Interface for the ClearingHouse contract
interface IClearingHouse {
    /// @notice Represents the side of an order (Bid = buying, Ask = selling)
    enum Side {
        Bid,
        Ask
    }

    /// @notice Structure representing a signed order
    /// @param creator Address of the order creator
    /// @param executor Address authorized to execute the order
    /// @param nonce Unique number to prevent replay attacks
    /// @param quantity Amount of baseToken to trade
    /// @param limitPrice Maximum/minimum price acceptable for the trade
    /// @param stopPrice Price at which the order becomes active
    /// @param expireTimestamp Time after which the order is invalid
    /// @param side Whether this is a bid (buy) or ask (sell) order
    /// @param onlyFullFill If true, order must be filled completely or not at all
    struct Order {
        address owner;
        address executor;
        uint256 nonce;
        uint256 quantity;
        uint256 limitPrice;
        uint256 stopPrice;
        uint256 expireTimestamp;
        Side side;
        bool onlyFullFill;
    }

    /// @notice Returns the base token address
    function baseToken() external view returns (address);

    /// @notice Returns the quote token address
    function quoteToken() external view returns (address);

    /// @notice Returns the filled quantity for a given order hash
    function pastOrders(bytes32 orderHash) external view returns (uint256);

    /// @notice Returns the price of the last executed trade
    function lastExecutionPrice() external view returns (uint256);

    /// @notice Executes a trade between a main order and multiple counter orders
    function execute(
        Order calldata mainOrder,
        Order[] calldata counterOrders,
        bytes calldata mainSignature,
        bytes[] calldata counterSignatures
    ) external;

    /// @notice Cancels an order by marking it as completely filled
    function cancelOrder(Order calldata order) external;

    /// @notice Computes the EIP-712 hash of an order
    function hashOrder(Order calldata order) external pure returns (bytes32);

    /// @notice Returns the EIP-712 domain separator
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
