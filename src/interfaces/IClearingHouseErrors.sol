// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IClearingHouseErrors {
    /// @notice Thrown when an address parameter is zero
    error ZeroAddress();

    /// @notice Thrown when an order has expired
    error OrderExpired(uint256 expireTimestamp, uint256 currentTimestamp);

    /// @notice Thrown when the executor is not authorized
    error UnauthorizedExecutor(address executor, address sender);

    /// @notice Thrown when stop price conditions are not met
    error InvalidStopPrice(uint256 stopPrice, uint256 lastExecutionPrice, uint8 side);

    /// @notice Thrown when signature verification fails
    error InvalidSignature(address signer, address orderOwner);

    /// @notice Thrown when order is already filled
    error OrderAlreadyFilled(bytes32 orderHash, uint256 quantity);

    /// @notice Thrown when order sides match (should be opposite)
    error InvalidOrderSides(uint8 mainOrderSide, uint8 counterOrderSide);

    /// @notice Thrown when token pairs don't match
    error TokenPairMismatch(
        address mainBaseToken, address mainQuoteToken, address counterBaseToken, address counterQuoteToken
    );

    /// @notice Thrown when price conditions are not met
    error InvalidPrice(uint256 limitPrice, uint256 executionPrice, uint8 side);

    /// @notice Thrown when quantity is zero
    error ZeroQuantity();

    /// @notice Thrown when full fill condition is not met
    error FullFillRequired(uint256 expectedQuantity, uint256 actualQuantity);

    /// @notice Thrown when caller is not the order maker
    error UnauthorizedCancellation(address caller, address maker);
}
