// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

interface ITreasury
{
    function epoch() external view returns (uint256);
    
    function nextEpochPoint() external view returns (uint256);

    function getPriceRatio() external view returns (uint256);
}