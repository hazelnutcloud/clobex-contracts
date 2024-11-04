// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClearingHouse} from "../src/ClearingHouse.sol";
import {IClearingHouse} from "../src/interfaces/IClearingHouse.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ClearingHouseTest is Test {
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    ClearingHouse public clearingHouse;
    MockERC20 public baseToken;
    MockERC20 public quoteToken;

    address public trader1;
    address public trader2;
    address public executor;
    uint256 public trader1PrivateKey;
    uint256 public trader2PrivateKey;
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
        (trader1, trader1PrivateKey) = makeAddrAndKey("trader1");
        (trader2, trader2PrivateKey) = makeAddrAndKey("trader2");
        (executor, executorPrivateKey) = makeAddrAndKey("executor");

        // Mint tokens to makers
        baseToken.mint(trader1, INITIAL_BALANCE);
        baseToken.mint(trader2, INITIAL_BALANCE);
        quoteToken.mint(trader1, INITIAL_BALANCE);
        quoteToken.mint(trader2, INITIAL_BALANCE);

        // Approve clearing house
        vm.startPrank(trader1);
        baseToken.approve(address(clearingHouse), type(uint256).max);
        quoteToken.approve(address(clearingHouse), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader2);
        baseToken.approve(address(clearingHouse), type(uint256).max);
        quoteToken.approve(address(clearingHouse), type(uint256).max);
        vm.stopPrank();
    }

    function _createOrder(
        address owner,
        uint256 quantity,
        uint256 limitPrice,
        uint256 stopPrice,
        uint256 expireTimestamp,
        ClearingHouse.Side side,
        bool onlyFullFill
    ) internal view returns (ClearingHouse.Order memory) {
        return IClearingHouse.Order({
            owner: owner,
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
        bytes32 digest = MessageHashUtils.toTypedDataHash(clearingHouse.DOMAIN_SEPARATOR(), orderHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_ExecuteSimpleTrade() public {
        vm.startPrank(executor);

        // Create a market bid order
        ClearingHouse.Order memory mainOrder = _createOrder(
            trader1,
            10e18, // quantity
            type(uint256).max, // limitPrice
            0, // stopPrice
            block.timestamp + 1 days,
            IClearingHouse.Side.Bid,
            false
        );

        // Create a matching ask limit order
        ClearingHouse.Order memory counterOrder = _createOrder(
            trader2, 10e18, 100e18, type(uint256).max, block.timestamp + 1 days, IClearingHouse.Side.Ask, false
        );

        ClearingHouse.Order[] memory counterOrders = new ClearingHouse.Order[](1);
        counterOrders[0] = counterOrder;

        bytes memory mainSignature = _signOrder(mainOrder, trader1PrivateKey);
        bytes[] memory counterSignatures = new bytes[](1);
        counterSignatures[0] = _signOrder(counterOrder, trader2PrivateKey);

        // Record balances before
        uint256 trader1BaseBalanceBefore = baseToken.balanceOf(trader1);
        uint256 trader1QuoteBalanceBefore = quoteToken.balanceOf(trader1);
        uint256 trader2BaseBalanceBefore = baseToken.balanceOf(trader2);
        uint256 trader2QuoteBalanceBefore = quoteToken.balanceOf(trader2);

        // Execute orders
        clearingHouse.execute(mainOrder, counterOrders, mainSignature, counterSignatures);

        // Verify balances after
        assertEq(baseToken.balanceOf(trader1), trader1BaseBalanceBefore + 10e18);
        assertEq(quoteToken.balanceOf(trader1), trader1QuoteBalanceBefore - 1000e18);
        assertEq(baseToken.balanceOf(trader2), trader2BaseBalanceBefore - 10e18);
        assertEq(quoteToken.balanceOf(trader2), trader2QuoteBalanceBefore + 1000e18);

        vm.stopPrank();
    }

    function test_RevertWhen_OrderExpired() public {
        vm.startPrank(executor);

        ClearingHouse.Order memory mainOrder = _createOrder(
            trader1,
            10e18,
            100e18,
            0,
            block.timestamp - 1, // Expired
            IClearingHouse.Side.Bid,
            false
        );

        ClearingHouse.Order memory counterOrder =
            _createOrder(trader2, 10e18, 100e18, 0, block.timestamp + 1 days, IClearingHouse.Side.Ask, false);

        ClearingHouse.Order[] memory counterOrders = new ClearingHouse.Order[](1);
        counterOrders[0] = counterOrder;

        bytes memory mainSignature = _signOrder(mainOrder, trader1PrivateKey);
        bytes[] memory counterSignatures = new bytes[](1);
        counterSignatures[0] = _signOrder(counterOrder, trader2PrivateKey);

        vm.expectRevert(); // Order expired
        clearingHouse.execute(mainOrder, counterOrders, mainSignature, counterSignatures);

        vm.stopPrank();
    }

    function test_FullFillOnly() public {
        vm.startPrank(executor);

        ClearingHouse.Order memory mainOrder = _createOrder(
            trader1,
            10e18,
            100e18,
            0,
            block.timestamp + 1 days,
            IClearingHouse.Side.Bid,
            true // Only full fill
        );

        // Counter order with smaller quantity - should fail
        ClearingHouse.Order memory counterOrder = _createOrder(
            trader2,
            5e18, // Half the quantity
            100e18,
            0,
            block.timestamp + 1 days,
            IClearingHouse.Side.Ask,
            false
        );

        ClearingHouse.Order[] memory counterOrders = new ClearingHouse.Order[](1);
        counterOrders[0] = counterOrder;

        bytes memory mainSignature = _signOrder(mainOrder, trader1PrivateKey);
        bytes[] memory counterSignatures = new bytes[](1);
        counterSignatures[0] = _signOrder(counterOrder, trader2PrivateKey);

        vm.expectRevert(); // Cannot partially fill
        clearingHouse.execute(mainOrder, counterOrders, mainSignature, counterSignatures);

        vm.stopPrank();
    }

    function test_CancelOrder() public {
        ClearingHouse.Order memory order =
            _createOrder(trader1, 10e18, 100e18, 0, block.timestamp + 1 days, IClearingHouse.Side.Bid, false);

        vm.prank(trader1);
        clearingHouse.cancelOrder(order);

        bytes32 orderHash = clearingHouse.hashOrder(order);
        assertEq(clearingHouse.pastOrders(orderHash), order.quantity);
    }
}
