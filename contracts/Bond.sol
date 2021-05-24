// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

import "./utils/Operator.sol";

contract DjinnGoldBond is ERC20Burnable, Operator
{
    constructor() ERC20("Djinn Gold Bond", "DJINNB") {}

    function mint(address _recipient, uint256 _amount) public onlyOperator returns (bool)
    {
        uint256 balanceBefore = balanceOf(_recipient);
        _mint(_recipient, _amount);
        uint256 balanceAfter = balanceOf(_recipient);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override
    {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator
    {
        super.burnFrom(account, amount);
    }

    function recoverUnsupported(address _token, uint256 _amount, address _to) external onlyOperator
    {
        IERC20(_token).transfer(_to, _amount);
    }
}