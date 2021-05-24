// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

interface IMint
{
    function mint(address recipient, uint256 amount) external returns (bool);
}