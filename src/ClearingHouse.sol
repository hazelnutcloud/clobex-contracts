// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "./interfaces/IClearingHouse.sol";
import "./interfaces/IClearingHouseErrors.sol";
import "./interfaces/IClearingHouseEvents.sol";

/// @title ClearingHouse
/// @notice A decentralized clearing house for executing orders with EIP-712 signatures
/// @dev Implements only execution with price and quantity checks. Order matching and book-keeping is done off-chain.
contract ClearingHouse is IClearingHouse, IClearingHouseErrors, IClearingHouseEvents, EIP712 {
    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address owner,address executor,uint256 nonce,uint256 quantity,uint256 limitPrice,uint256 stopPrice,uint256 expireTimestamp,uint8 side,bool onlyFullFill)"
    );

    address public immutable baseToken;
    address public immutable quoteToken;

    /// @notice Tracks the filled quantity for each order hash
    mapping(bytes32 orderHash => uint256 filledQuantity) public pastOrders;

    /// @notice The price at which the last trade was executed
    uint256 public lastExecutionPrice;

    constructor(uint256 initialExecutionPrice, address baseToken_, address quoteToken_) EIP712("ClearingHouse", "1") {
        lastExecutionPrice = initialExecutionPrice;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
    }

    /* -------------------------------------------------------------------------- */
    /*                              Public Functions                              */
    /* -------------------------------------------------------------------------- */

    /// @notice Executes a trade between a taker order and multiple maker orders
    /// @param takerOrder The primary order to be executed
    /// @param makerOrders Array of matching orders to trade against
    /// @param takerSignature EIP-712 signature for the taker order
    /// @param makerSignatures Array of EIP-712 signatures for maker orders
    /// @dev All maker orders must be limit orders
    function execute(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        bytes calldata takerSignature,
        bytes[] calldata makerSignatures
    ) external {
        (bytes32 takerOrderHash, uint256 takerOrderFilledQuantity) =
            _verifyAndGetFilledQuantity(takerOrder, takerSignature);
        uint256 takerOrderAvailableQuantity = takerOrder.quantity - takerOrderFilledQuantity;

        uint256 baseTokenScaleFactor = 10 ** IERC20Metadata(baseToken).decimals();

        uint256 executionPrice;

        uint256[] memory baseQuantities = new uint256[](makerOrders.length);
        uint256[] memory quoteQuantities = new uint256[](makerOrders.length);
        bytes32[] memory makerOrderHashes = new bytes32[](makerOrders.length);

        for (uint256 i = 0; i < makerOrders.length; i++) {
            Order calldata makerOrder = makerOrders[i];
            (bytes32 makerOrderHash, uint256 makerOrderFilledQuantity) =
                _verifyAndGetFilledQuantity(makerOrder, makerSignatures[i]);

            makerOrderHashes[i] = makerOrderHash;

            // Verify order sides
            if (makerOrder.side == takerOrder.side) {
                revert InvalidOrderSides(uint8(takerOrder.side), uint8(makerOrder.side));
            }

            executionPrice = makerOrder.limitPrice;

            // Verify prices
            if (takerOrder.side == Side.Bid) {
                if (executionPrice == 0 || takerOrder.limitPrice < executionPrice) {
                    revert InvalidPrice(takerOrder.limitPrice, executionPrice, uint8(takerOrder.side));
                }
            } else {
                if (executionPrice == type(uint256).max || takerOrder.limitPrice > executionPrice) {
                    revert InvalidPrice(takerOrder.limitPrice, executionPrice, uint8(takerOrder.side));
                }
            }

            // Calculate and verify quantities
            uint256 makerOrderAvailableQuantity = makerOrder.quantity - makerOrderFilledQuantity;

            uint256 baseQuantity = takerOrderAvailableQuantity < makerOrderAvailableQuantity
                ? takerOrderAvailableQuantity
                : makerOrderAvailableQuantity;

            if (baseQuantity == 0) {
                revert ZeroQuantity();
            }

            if (makerOrder.onlyFullFill && baseQuantity != makerOrder.quantity) {
                revert FullFillRequired(makerOrder.quantity, baseQuantity);
            }

            uint256 quoteQuantity = (executionPrice * baseQuantity) / baseTokenScaleFactor;

            takerOrderAvailableQuantity -= baseQuantity;
            baseQuantities[i] = baseQuantity;
            quoteQuantities[i] = quoteQuantity;
        }

        // Verify full fill
        if (takerOrder.onlyFullFill && takerOrderAvailableQuantity > 0) {
            revert FullFillRequired(takerOrder.quantity, takerOrder.quantity - takerOrderAvailableQuantity);
        }

        // Update past orders
        pastOrders[takerOrderHash] = takerOrder.quantity - takerOrderAvailableQuantity;

        // Update execution price
        lastExecutionPrice = executionPrice;

        for (uint256 i = 0; i < makerOrders.length; i++) {
            Order calldata makerOrder = makerOrders[i];
            // Update past orders
            pastOrders[makerOrderHashes[i]] += baseQuantities[i];

            // Transfer assets
            if (takerOrder.side == Side.Bid) {
                IERC20(baseToken).transferFrom(makerOrder.owner, takerOrder.owner, baseQuantities[i]);
                IERC20(quoteToken).transferFrom(takerOrder.owner, makerOrder.owner, quoteQuantities[i]);
            } else {
                IERC20(quoteToken).transferFrom(makerOrder.owner, takerOrder.owner, quoteQuantities[i]);
                IERC20(baseToken).transferFrom(takerOrder.owner, makerOrder.owner, baseQuantities[i]);
            }

            // Emit event for each execution
            emit OrderExecuted(
                takerOrderHash,
                makerOrderHashes[i],
                executionPrice,
                baseQuantities[i],
                quoteQuantities[i],
                makerOrder.owner,
                takerOrder.owner
            );
        }
    }

    /// @notice Cancels an order by marking it as completely filled
    /// @param order The order to cancel
    /// @dev Can only be called by the order maker
    function cancelOrder(Order calldata order) external {
        if (order.owner != msg.sender) {
            revert UnauthorizedCancellation(msg.sender, order.owner);
        }

        bytes32 orderHash = hashOrder(order);
        pastOrders[orderHash] = order.quantity;

        // Emit cancel event
        emit OrderCancelled(orderHash, msg.sender);
    }

    /// @notice Computes the EIP-712 hash of an order
    /// @param order The order to hash
    /// @return The hash of the order
    function hashOrder(Order calldata order) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.owner,
                order.executor,
                order.nonce,
                order.quantity,
                order.limitPrice,
                order.stopPrice,
                order.expireTimestamp,
                order.side,
                order.onlyFullFill
            )
        );
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /* -------------------------------------------------------------------------- */
    /*                             Internal Functions                             */
    /* -------------------------------------------------------------------------- */

    /// @notice Verifies an order's validity and returns its filled quantity
    /// @param order The order to verify
    /// @param signature The EIP-712 signature to verify
    /// @return orderHash The computed hash of the order
    /// @return filledQuantity The amount of the order that has been filled
    /// @dev Checks for zero addresses, expiration, executor authorization, and stop price conditions
    function _verifyAndGetFilledQuantity(Order calldata order, bytes calldata signature)
        internal
        view
        returns (bytes32 orderHash, uint256 filledQuantity)
    {
        if (order.owner == address(0) || order.executor == address(0)) {
            revert ZeroAddress();
        }

        if (order.expireTimestamp <= block.timestamp) {
            revert OrderExpired(order.expireTimestamp, block.timestamp);
        }

        if (order.executor != msg.sender) {
            revert UnauthorizedExecutor(order.executor, msg.sender);
        }

        if (order.side == Side.Bid) {
            if (order.stopPrice > lastExecutionPrice) {
                revert InvalidStopPrice(order.stopPrice, lastExecutionPrice, uint8(order.side));
            }
        } else {
            if (order.stopPrice < lastExecutionPrice) {
                revert InvalidStopPrice(order.stopPrice, lastExecutionPrice, uint8(order.side));
            }
        }

        orderHash = hashOrder(order);
        if (!_verifyOrderSignature(orderHash, order.owner, signature)) {
            revert InvalidSignature(msg.sender, order.owner);
        }

        filledQuantity = pastOrders[orderHash];
        if (filledQuantity >= order.quantity) {
            revert OrderAlreadyFilled(orderHash, order.quantity);
        }
    }

    /// @notice Verifies that an order signature is valid
    /// @param orderHash The hash of the order being verified
    /// @param orderOwner The purported signer of the order
    /// @param signature The signature to verify
    /// @return True if the signature is valid, false otherwise
    /// @dev Uses EIP-712 for signature verification
    function _verifyOrderSignature(bytes32 orderHash, address orderOwner, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        bytes32 typedDataHash = _hashTypedDataV4(orderHash);

        address signer = ECDSA.recover(typedDataHash, signature);
        return signer == orderOwner;
    }
}
