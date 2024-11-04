// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/IClearingHouseErrors.sol";

/// @title ClearingHouse
/// @notice A decentralized clearing house for executing orders with EIP-712 signatures
/// @dev Implements only execution with price and quantity checks. Order matching and book-keeping is done off-chain.
contract ClearingHouse is IClearingHouseErrors {
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 private constant ORDER_TYPEHASH =
        keccak256(
            "Order(address maker,address executor,uint256 nonce,uint256 quantity,uint256 limitPrice,uint256 stopPrice,uint256 expireTimestamp,uint8 side,bool onlyFullFill)"
        );
    bytes32 public immutable DOMAIN_SEPARATOR;
    address public immutable baseToken;
    address public immutable quoteToken;

    /// @notice Represents the side of an order (Bid = buying, Ask = selling)
    enum Side {
        Bid,
        Ask
    }

    /// @notice Structure representing a signed order
    /// @param maker Address of the order creator
    /// @param executor Address authorized to execute the order
    /// @param baseToken Address of the token being traded
    /// @param quoteToken Address of the token used for pricing
    /// @param nonce Unique number to prevent replay attacks
    /// @param quantity Amount of baseToken to trade
    /// @param limitPrice Maximum/minimum price acceptable for the trade
    /// @param stopPrice Price at which the order becomes active
    /// @param expireTimestamp Time after which the order is invalid
    /// @param side Whether this is a bid (buy) or ask (sell) order
    /// @param onlyFullFill If true, order must be filled completely or not at all
    struct Order {
        address maker;
        address executor;
        uint256 nonce;
        uint256 quantity;
        uint256 limitPrice;
        uint256 stopPrice;
        uint256 expireTimestamp;
        Side side;
        bool onlyFullFill;
    }

    /// @notice Tracks the filled quantity for each order hash
    mapping(bytes32 orderHash => uint256 filledQuantity) public pastOrders;

    /// @notice The price at which the last trade was executed
    uint256 public lastExecutionPrice;

    constructor(
        uint256 initialExecutionPrice,
        address baseToken_,
        address quoteToken_
    ) {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("ClearingHouse")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
        lastExecutionPrice = initialExecutionPrice;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
    }

    /* -------------------------------------------------------------------------- */
    /*                              Public Functions                              */
    /* -------------------------------------------------------------------------- */

    /// @notice Executes a trade between a main order and multiple counter orders
    /// @param mainOrder The primary order to be executed
    /// @param counterOrders Array of matching orders to trade against
    /// @param mainSignature EIP-712 signature for the main order
    /// @param counterSignatures Array of EIP-712 signatures for counter orders
    /// @dev All counter orders must be limit orders
    function execute(
        Order calldata mainOrder,
        Order[] calldata counterOrders,
        bytes calldata mainSignature,
        bytes[] calldata counterSignatures
    ) external {
        (
            bytes32 mainOrderHash,
            uint256 mainOrderFilledQuantity
        ) = _verifyAndGetFilledQuantity(mainOrder, mainSignature);
        uint256 mainOrderAvailableQuantity = mainOrder.quantity -
            mainOrderFilledQuantity;

        uint256 baseTokenScaleFactor = 10 **
            IERC20Metadata(baseToken).decimals();

        uint256 executionPrice;

        uint256[] memory baseQuantities = new uint256[](counterOrders.length);
        uint256[] memory quoteQuantities = new uint256[](counterOrders.length);
        bytes32[] memory counterOrderHashes = new bytes32[](
            counterOrders.length
        );

        for (uint256 i = 0; i < counterOrders.length; i++) {
            Order calldata counterOrder = counterOrders[i];
            (
                bytes32 counterOrderHash,
                uint256 counterOrderFilledQuantity
            ) = _verifyAndGetFilledQuantity(counterOrder, counterSignatures[i]);

            counterOrderHashes[i] = counterOrderHash;

            // Verify order sides
            if (counterOrder.side == mainOrder.side) {
                revert InvalidOrderSides(
                    uint8(mainOrder.side),
                    uint8(counterOrder.side)
                );
            }

            executionPrice = counterOrder.limitPrice;

            // Verify prices
            if (mainOrder.side == Side.Bid) {
                if (
                    executionPrice == 0 || mainOrder.limitPrice < executionPrice
                ) {
                    revert InvalidPrice(
                        mainOrder.limitPrice,
                        executionPrice,
                        uint8(mainOrder.side)
                    );
                }
            } else {
                if (
                    executionPrice == type(uint256).max ||
                    mainOrder.limitPrice > executionPrice
                ) {
                    revert InvalidPrice(
                        mainOrder.limitPrice,
                        executionPrice,
                        uint8(mainOrder.side)
                    );
                }
            }

            // Calculate and verify quantities
            uint256 counterOrderAvailableQuantity = counterOrder.quantity -
                counterOrderFilledQuantity;

            uint256 baseQuantity = mainOrderAvailableQuantity <
                counterOrderAvailableQuantity
                ? mainOrderAvailableQuantity
                : counterOrderAvailableQuantity;

            if (baseQuantity == 0) {
                revert ZeroQuantity();
            }

            if (
                counterOrder.onlyFullFill &&
                baseQuantity != counterOrder.quantity
            ) {
                revert FullFillRequired(counterOrder.quantity, baseQuantity);
            }

            uint256 quoteQuantity = (executionPrice * baseQuantity) /
                baseTokenScaleFactor;

            mainOrderAvailableQuantity -= baseQuantity;
            baseQuantities[i] = baseQuantity;
            quoteQuantities[i] = quoteQuantity;
        }

        // Verify full fill
        if (mainOrder.onlyFullFill && mainOrderAvailableQuantity > 0) {
            revert FullFillRequired(
                mainOrder.quantity,
                mainOrder.quantity - mainOrderAvailableQuantity
            );
        }

        // Update past orders
        pastOrders[mainOrderHash] =
            mainOrder.quantity -
            mainOrderAvailableQuantity;

        // Update execution price
        lastExecutionPrice = executionPrice;

        for (uint256 i = 0; i < counterOrders.length; i++) {
            Order calldata counterOrder = counterOrders[i];
            // Update past orders
            pastOrders[counterOrderHashes[i]] += baseQuantities[i];

            // Transfer assets
            if (mainOrder.side == Side.Bid) {
                IERC20(baseToken).transferFrom(
                    counterOrder.maker,
                    mainOrder.maker,
                    baseQuantities[i]
                );
                IERC20(quoteToken).transferFrom(
                    mainOrder.maker,
                    counterOrder.maker,
                    quoteQuantities[i]
                );
            } else {
                IERC20(quoteToken).transferFrom(
                    counterOrder.maker,
                    mainOrder.maker,
                    quoteQuantities[i]
                );
                IERC20(baseToken).transferFrom(
                    mainOrder.maker,
                    counterOrder.maker,
                    baseQuantities[i]
                );
            }
        }
    }

    /// @notice Cancels an order by marking it as completely filled
    /// @param order The order to cancel
    /// @dev Can only be called by the order maker
    function cancelOrder(Order calldata order) external {
        if (order.maker != msg.sender) {
            revert UnauthorizedCancellation(msg.sender, order.maker);
        }

        bytes32 orderHash = hashOrder(order);
        pastOrders[orderHash] = order.quantity;
    }

    /// @notice Computes the EIP-712 hash of an order
    /// @param order The order to hash
    /// @return The hash of the order
    function hashOrder(Order calldata order) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.maker,
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

    /* -------------------------------------------------------------------------- */
    /*                             Internal Functions                             */
    /* -------------------------------------------------------------------------- */

    /// @notice Verifies an order's validity and returns its filled quantity
    /// @param order The order to verify
    /// @param signature The EIP-712 signature to verify
    /// @return orderHash The computed hash of the order
    /// @return filledQuantity The amount of the order that has been filled
    /// @dev Checks for zero addresses, expiration, executor authorization, and stop price conditions
    function _verifyAndGetFilledQuantity(
        Order calldata order,
        bytes calldata signature
    ) internal view returns (bytes32 orderHash, uint256 filledQuantity) {
        if (order.maker == address(0) || order.executor == address(0)) {
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
                revert InvalidStopPrice(
                    order.stopPrice,
                    lastExecutionPrice,
                    uint8(order.side)
                );
            }
        } else {
            if (order.stopPrice < lastExecutionPrice) {
                revert InvalidStopPrice(
                    order.stopPrice,
                    lastExecutionPrice,
                    uint8(order.side)
                );
            }
        }

        orderHash = hashOrder(order);
        if (!_verifyOrderSignature(orderHash, order.maker, signature)) {
            revert InvalidSignature(msg.sender, order.maker);
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
    function _verifyOrderSignature(
        bytes32 orderHash,
        address orderOwner,
        bytes calldata signature
    ) internal view returns (bool) {
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, orderHash)
        );

        address signer = ECDSA.recover(digest, signature);
        return signer == orderOwner;
    }
}
