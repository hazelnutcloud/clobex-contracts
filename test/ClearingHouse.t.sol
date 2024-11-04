// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ClearingHouseTest is Test {
    ClearingHouse public clearingHouse;
    MockERC20 public baseToken;
    MockERC20 public quoteToken;

    address public maker1;
    address public maker2;
    address public executor;
    uint256 public maker1PrivateKey;
    uint256 public maker2PrivateKey;
    uint256 public executorPrivateKey;

    // Initial balances and prices
    uint256 constant INITIAL_BALANCE = 1000e18;
    uint256 constant INITIAL_PRICE = 100e18;

    function setUp() public {
        // Deploy tokens
        baseToken = new MockERC20("Base Token", "BASE", 18);
        quoteToken = new MockERC20("Quote Token", "QUOTE", 18);

        // Deploy clearing house
        clearingHouse = new ClearingHouse(INITIAL_PRICE, address(baseToken), address(quoteToken));

        // Setup accounts
        (maker1, maker1PrivateKey) = makeAddrAndKey("maker1");
        (maker2, maker2PrivateKey) = makeAddrAndKey("maker2");
        (executor, executorPrivateKey) = makeAddrAndKey("executor");

        // Mint tokens to makers
        baseToken.mint(maker1, INITIAL_BALANCE);
        baseToken.mint(maker2, INITIAL_BALANCE);
        quoteToken.mint(maker1, INITIAL_BALANCE);
        quoteToken.mint(maker2, INITIAL_BALANCE);

        // Approve clearing house
        vm.startPrank(maker1);
        baseToken.approve(address(clearingHouse), type(uint256).max);
        quoteToken.approve(address(clearingHouse), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(maker2);
        baseToken.approve(address(clearingHouse), type(uint256).max);
        quoteToken.approve(address(clearingHouse), type(uint256).max);
        vm.stopPrank();
    }

    function _createOrder(
        address maker,
        uint256 quantity,
        uint256 limitPrice,
        uint256 stopPrice,
        uint256 expireTimestamp,
        ClearingHouse.Side side,
        bool onlyFullFill
    ) internal view returns (ClearingHouse.Order memory) {
        return ClearingHouse.Order({
            maker: maker,
            executor: executor,
            nonce: 0,
            quantity: quantity,
            limitPrice: limitPrice,
            stopPrice: stopPrice,
            expireTimestamp: expireTimestamp,
            side: side,
            onlyFullFill: onlyFullFill
        });
    }

    function _signOrder(ClearingHouse.Order memory order, uint256 privateKey) internal view returns (bytes memory) {
        bytes32 orderHash = clearingHouse.hashOrder(order);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", clearingHouse.DOMAIN_SEPARATOR(), orderHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_ExecuteSimpleTrade() public {
        vm.startPrank(executor);

        // Create a market bid order
        ClearingHouse.Order memory mainOrder = _createOrder(
            maker1,
            10e18, // quantity
            type(uint256).max, // limitPrice
            0, // stopPrice
            block.timestamp + 1 days,
            ClearingHouse.Side.Bid,
            false
        );

        // Create a matching ask limit order
        ClearingHouse.Order memory counterOrder = _createOrder(
            maker2, 10e18, 100e18, type(uint256).max, block.timestamp + 1 days, ClearingHouse.Side.Ask, false
        );

        ClearingHouse.Order[] memory counterOrders = new ClearingHouse.Order[](1);
        counterOrders[0] = counterOrder;

        bytes memory mainSignature = _signOrder(mainOrder, maker1PrivateKey);
        bytes[] memory counterSignatures = new bytes[](1);
        counterSignatures[0] = _signOrder(counterOrder, maker2PrivateKey);

        // Record balances before
        uint256 maker1BaseBalanceBefore = baseToken.balanceOf(maker1);
        uint256 maker1QuoteBalanceBefore = quoteToken.balanceOf(maker1);
        uint256 maker2BaseBalanceBefore = baseToken.balanceOf(maker2);
        uint256 maker2QuoteBalanceBefore = quoteToken.balanceOf(maker2);

        // Execute orders
        clearingHouse.execute(mainOrder, counterOrders, mainSignature, counterSignatures);

        // Verify balances after
        assertEq(baseToken.balanceOf(maker1), maker1BaseBalanceBefore + 10e18);
        assertEq(quoteToken.balanceOf(maker1), maker1QuoteBalanceBefore - 1000e18);
        assertEq(baseToken.balanceOf(maker2), maker2BaseBalanceBefore - 10e18);
        assertEq(quoteToken.balanceOf(maker2), maker2QuoteBalanceBefore + 1000e18);

        vm.stopPrank();
    }

    function test_RevertWhen_OrderExpired() public {
        vm.startPrank(executor);

        ClearingHouse.Order memory mainOrder = _createOrder(
            maker1,
            10e18,
            100e18,
            0,
            block.timestamp - 1, // Expired
            ClearingHouse.Side.Bid,
            false
        );

        ClearingHouse.Order memory counterOrder =
            _createOrder(maker2, 10e18, 100e18, 0, block.timestamp + 1 days, ClearingHouse.Side.Ask, false);

        ClearingHouse.Order[] memory counterOrders = new ClearingHouse.Order[](1);
        counterOrders[0] = counterOrder;

        bytes memory mainSignature = _signOrder(mainOrder, maker1PrivateKey);
        bytes[] memory counterSignatures = new bytes[](1);
        counterSignatures[0] = _signOrder(counterOrder, maker2PrivateKey);

        vm.expectRevert(); // Order expired
        clearingHouse.execute(mainOrder, counterOrders, mainSignature, counterSignatures);

        vm.stopPrank();
    }

    function test_FullFillOnly() public {
        vm.startPrank(executor);

        ClearingHouse.Order memory mainOrder = _createOrder(
            maker1,
            10e18,
            100e18,
            0,
            block.timestamp + 1 days,
            ClearingHouse.Side.Bid,
            true // Only full fill
        );

        // Counter order with smaller quantity - should fail
        ClearingHouse.Order memory counterOrder = _createOrder(
            maker2,
            5e18, // Half the quantity
            100e18,
            0,
            block.timestamp + 1 days,
            ClearingHouse.Side.Ask,
            false
        );

        ClearingHouse.Order[] memory counterOrders = new ClearingHouse.Order[](1);
        counterOrders[0] = counterOrder;

        bytes memory mainSignature = _signOrder(mainOrder, maker1PrivateKey);
        bytes[] memory counterSignatures = new bytes[](1);
        counterSignatures[0] = _signOrder(counterOrder, maker2PrivateKey);

        vm.expectRevert(); // Cannot partially fill
        clearingHouse.execute(mainOrder, counterOrders, mainSignature, counterSignatures);

        vm.stopPrank();
    }

    function test_CancelOrder() public {
        ClearingHouse.Order memory order =
            _createOrder(maker1, 10e18, 100e18, 0, block.timestamp + 1 days, ClearingHouse.Side.Bid, false);

        vm.prank(maker1);
        clearingHouse.cancelOrder(order);

        bytes32 orderHash = clearingHouse.hashOrder(order);
        assertEq(clearingHouse.pastOrders(orderHash), order.quantity);
    }
}
