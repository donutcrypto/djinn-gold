// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

interface IRecovery
{
    function recoverUnsupported(address _token, uint256 _amount, address _to) external;
}