// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

interface IBurn
{
    function burn(uint256 amount) external;

    function burnFrom(address from, uint256 amount) external;
}