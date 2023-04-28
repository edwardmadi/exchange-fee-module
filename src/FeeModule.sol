// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { ERC1155TokenReceiver } from "solmate/tokens/ERC1155.sol";

import { Auth } from "./mixins/Auth.sol";
import { Transfers } from "./mixins/Transfers.sol";

import { IExchange } from "./interfaces/IExchange.sol";
import { IFeeModule } from "./interfaces/IFeeModule.sol";

import { Order, Side } from "./libraries/Structs.sol";
import { CalculatorHelper } from "./libraries/CalculatorHelper.sol";

/// @title Polymarket CTF Fee Module
/// @notice Proxies the CTFExchange contract and refunds maker orders
/// @author Jon Amenechi (jon@polymarket.com)
contract FeeModule is IFeeModule, Auth, Transfers, ERC1155TokenReceiver {
    
    /// @notice The Exchange contract
    IExchange public immutable exchange;

    /// @notice The collateral token
    address public immutable collateral;

    /// @notice The CTF contract
    address public immutable ctf;

    constructor(address _exchange) {
        exchange = IExchange(_exchange);
        collateral = exchange.getCollateral();
        ctf = exchange.getCtf();
    }

    /// @notice Matches a taker order against a list of maker orders, refunding maker order fees if necessary
    /// @param takerOrder       - The active order to be matched
    /// @param makerOrders      - The array of maker orders to be matched against the active order
    /// @param takerFillAmount  - The amount to fill on the taker order, always in terms of the maker amount
    /// @param makerFillAmounts - The array of amounts to fill on the maker orders, always in terms of the maker amount
    function matchOrders(
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external onlyAdmin {
        // Match the orders on the exchange
        exchange.matchOrders(takerOrder, makerOrders, takerFillAmount, makerFillAmounts);

        // Refund maker fees
        _refundFees(makerOrders, makerFillAmounts);
    }

    /// @notice Withdraw collected fees
    /// @param id       - The tokenID to be withdrawn. If 0, will be the collateral token. 
    /// @param amount   - The amount to be withdrawn
    function withdrawFees(address to, uint256 id, uint256 amount) external onlyAdmin {
        address token = id == 0 ? collateral : ctf;
        _transfer(token, address(this), to, id, amount);
        emit FeeWithdrawn(token, to, id, amount);
     }

    /// @notice Refund fees for a set of orders
    /// @param orders       - The array of orders
    /// @param fillAmounts  - The array of fill amounts for the orders
    function _refundFees(Order[] memory orders, uint256[] memory fillAmounts) internal {
        uint256 length = orders.length;
        uint256 i = 0;
        for (; i < length;) {
            _refundFee(orders[i], fillAmounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Refund fee for an order
    /// @param order        - The order
    /// @param fillAmount   - The fill amount for the order
    function _refundFee(Order memory order, uint256 fillAmount) internal {
        uint256 making = fillAmount;
        uint256 taking = CalculatorHelper.calculateTakingAmount(making, order.makerAmount, order.takerAmount);

        // Calculate fee for the order
        uint256 fee = CalculatorHelper.calculateFee(
            order.feeRateBps, order.side == Side.BUY ? taking : making, order.makerAmount, order.takerAmount, order.side
        );

        // If the order is a buy, proceeds, and fees, will be denominated in ERC1155 token
        uint256 id = order.side == Side.BUY ? order.tokenId : 0;
        address token = order.side == Side.BUY ? ctf : collateral;
        
        // If the fee is non-zero, refund the fee collected on the Module
        if(fee > 0) {
            _transfer(token, address(this), order.maker, id, fee);
            emit FeeRefunded(token, order.maker, id, fee);
        }
    }
}
