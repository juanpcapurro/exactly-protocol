// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;
import "../utils/TSUtils.sol";

interface IAuditor {
    // this one validates post liquidity check
    function validateBorrowMP(address fixedLenderAddress, address borrower)
        external;

    function getAccountLiquidity(address account)
        external
        view
        returns (uint256, uint256);

    function liquidateAllowed(
        address fixedLenderBorrowed,
        address fixedLenderCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external view;

    function seizeAllowed(
        address fixedLenderCollateral,
        address fixedLenderBorrowed,
        address liquidator,
        address borrower
    ) external view;

    function liquidateCalculateSeizeAmount(
        address fixedLenderBorrowed,
        address fixedLenderCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256);

    function getFuturePools() external view returns (uint256[] memory);

    function maxFuturePools() external view returns (uint8);

    function getMarketAddresses() external view returns (address[] memory);

    function requirePoolState(
        uint256 maturityDate,
        TSUtils.State requiredState,
        TSUtils.State alternativeState
    ) external view;

    function validateMarketListed(address fixedLenderAddress) external view;

    function validateAccountShortfall(
        address fixedLenderAddress,
        address account,
        uint256 amount
    ) external view;
}
