// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/AggregatorV3Interface.sol";
import "./interfaces/IBoardroom.sol";
import "./interfaces/IBurn.sol";
import "./interfaces/IMint.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IRecovery.sol";
import "./libs/Babylonian.sol";
import "./utils/ContractGuard.sol";
import "./utils/Operator.sol";

contract Treasury is ContractGuard
{
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct EpochRecord
    {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
        uint256 bondCoinSpent;
        uint256 bondAmountBought;
        uint256 bondCoinSupplied;
        uint256 bondAmountRedeemed;
        uint256 coinPrice;
        uint256 goldPrice;
        uint256 priceRatio;
    }

    /* ========= CONSTANT VARIABLES ======== */

    // unit
    uint256 public constant UNIT_ONE = 1e18;

    // epoch
    uint256 public constant START_TIME = 1618617600; // 2021-04-17 00:00:00
    uint256 public constant EPOCH_LENGTH = 4 hours;

    // price
    uint256 public constant PRICE_RATIO_CEILING = 101e16; // 1.01

    uint256 public constant MAX_EXPANSION_FACTOR = 200e14; // Up to 2.0% supply for expansion
    uint256 public constant SEIGNIORAGE_EXPANSION_FLOOR_FACTOR = 3000e14; // At least 30% of expansion reserved for boardroom

    uint256 public constant MAX_CONTRACTION_FACTOR = 200e14; // max 2.0% supply for contraction
    uint256 public constant MAX_DEBT_RATIO_FACTOR = 5000e14; // max 50% debt
        
    uint256 public constant OUNCE_TO_GRAM_FACTOR = 311034768e11; // 31.1034768
    address public constant AU_PRICE_FEED = 0x86896fEB19D8A607c3b11f2aF50A0f239Bd71CD0;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public migrated = false;

    // epoch
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public coin = address(0x24eacCa1086F2904962a32732590F27Ca45D1d99);
    address public share = address(0xb0168Bca7dB2eFe53b9112c08aae36D744800645);
    address public bond = address(0x2e976c9a80d0eeD5Bd80084365a87E59CFbb90A8);

    address public boardroom;
    address public oracle = address(0x0F462d212f0d26B4a565093cb67474D681D959e3);

    // price
    uint256 public previousEpochPriceRatio;

    // records
    EpochRecord[] public epochRecords;

    uint256 public currentEpochBondCoinSpent;
    uint256 public currentEpochBondAmountBought;

    uint256 public currentEpochBondCoinSupplied;
    uint256 public currentEpochBondAmountRedeemed;

    // game fund
    address public gameFund;
    uint256 public gameFundSharedPercent;

    constructor()
    {
        operator = msg.sender;
    }

    /* =================== Events =================== */

    event Migration(address indexed target);
    event RedeemedBonds(address indexed from, uint256 coinAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 coinAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event GameFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator()
    {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition
    {
        require(!migrated, "Treasury: migrated");
        require(block.timestamp >= START_TIME, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch
    {
        require(block.timestamp >= nextEpochPoint(), "Treasury: epoch not started yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getPriceRatio() > PRICE_RATIO_CEILING) ? 0 : IERC20(coin).totalSupply().mul(MAX_CONTRACTION_FACTOR).div(UNIT_ONE);
    }

    modifier checkOperator
    {
        require(
            Operator(coin).operator() == address(this) &&
                Operator(bond).operator() == address(this) &&
                Operator(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // epoch
    function nextEpochPoint() public view returns (uint256)
    {
        return START_TIME.add(epoch.mul(EPOCH_LENGTH));
    }

    // oracle
    function getPriceRatio() public view returns (uint256)
    {
        uint256 _coinPrice = getCoinPrice();
        uint256 _goldPrice = getGoldPrice();
        return UNIT_ONE.mul(_coinPrice).div(_goldPrice);
    }

    function getCoinPrice() public view returns (uint256)
    {
        try IOracle(oracle).consult(coin, UNIT_ONE) returns (uint144 price)
        {
            return uint256(price);
        }
        catch
        {
            revert("Treasury: failed to consult coin price from the oracle");
        }
    }

    function getPriceRatioUpdated() public view returns (uint256)
    {
        uint256 _coinPriceUpdated = getCoinPriceUpdated();
        uint256 _goldPrice = getGoldPrice();
        return UNIT_ONE.mul(_coinPriceUpdated).div(_goldPrice);
    }

    function getCoinPriceUpdated() public view returns (uint256)
    {
        try IOracle(oracle).twap(coin, UNIT_ONE) returns (uint144 price)
        {
            return uint256(price);
        }
        catch
        {
            revert("Treasury: failed to consult coin price from the oracle");
        }
    }

    function getGoldPrice() public view returns (uint256)
    {
        uint8 _decimals = AggregatorV3Interface(AU_PRICE_FEED).decimals();
        int256 _goldOuncePrice;
        (,_goldOuncePrice,,,) = AggregatorV3Interface(AU_PRICE_FEED).latestRoundData();
        return uint256(_goldOuncePrice).mul(UNIT_ONE).div(10**_decimals).mul(UNIT_ONE).div(OUNCE_TO_GRAM_FACTOR);
    }

    /* ========== GOVERNANCE ========== */

    function setOperator(address _operator) external onlyOperator
    {
        operator = _operator;
    }

    function setBoardroom(address _boardroom) external onlyOperator
    {
        boardroom = _boardroom;
    }

    function setGameFund(address _gameFund, uint256 _gameFundSharedPercent) external onlyOperator
    {
        require(_gameFund != address(0), "zero");
        require(_gameFundSharedPercent <= 2000e14, "out of range"); // =< 20%
        gameFund = _gameFund;
        gameFundSharedPercent = _gameFundSharedPercent;
    }

    function migrate(address target) external onlyOperator checkOperator
    {
        require(!migrated, "Treasury: migrated");

        // coin
        Operator(coin).transferOperator(target);
        Operator(coin).transferOwnership(target);
        IERC20(coin).transfer(target, IERC20(coin).balanceOf(address(this)));

        // bond
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        // boardroom
        if (boardroom != address(0))
        {
            IBoardroom(boardroom).setOperator(target);
        }

        migrated = true;
        emit Migration(target);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateCoinPrice() internal
    {
        try IOracle(oracle).update() {} catch {}
    }

    function buyBonds(uint256 _coinAmount) external onlyOneBlock checkCondition checkOperator
    {
        require(_coinAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 _priceRatio = getPriceRatio();
        require(
            _priceRatio < UNIT_ONE, // price ratio < 1.00
            "Treasury: price ratio must be below 1.00"
        );

        require(_coinAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _bondAmount = _coinAmount.mul(UNIT_ONE).div(_priceRatio);
        uint256 _coinSupply = IERC20(coin).totalSupply();
        uint256 _newBondSupply = IERC20(bond).totalSupply().add(_bondAmount);
        require(_newBondSupply <= _coinSupply.mul(MAX_DEBT_RATIO_FACTOR).div(UNIT_ONE), "Treasury: over max debt ratio");

        IBurn(coin).burnFrom(msg.sender, _coinAmount);
        IMint(bond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_coinAmount);
        _updateCoinPrice();

        currentEpochBondCoinSpent = currentEpochBondCoinSpent.add(_coinAmount);
        currentEpochBondAmountBought = currentEpochBondAmountBought.add(_bondAmount);
        emit BoughtBonds(msg.sender, _coinAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount) external onlyOneBlock checkCondition checkOperator
    {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 _priceRatio = getPriceRatio();
        require(
            _priceRatio > PRICE_RATIO_CEILING, // price ratio > 1.01
            "Treasury: price ratio must exceed 1.01"
        );

        require(IERC20(coin).balanceOf(address(this)) >= _bondAmount, "Treasury: insufficient budget");

        IBurn(bond).burnFrom(msg.sender, _bondAmount);
        IERC20(coin).safeTransfer(msg.sender, _bondAmount);

        _updateCoinPrice();

        currentEpochBondAmountRedeemed = currentEpochBondAmountRedeemed.add(_bondAmount);
        currentEpochBondCoinSupplied = currentEpochBondCoinSupplied.add(_bondAmount);
        emit RedeemedBonds(msg.sender, _bondAmount, _bondAmount);
    }

    function _sendToBoardRoom(uint256 _amount) internal
    {
        IMint(coin).mint(address(this), _amount);
        if (gameFundSharedPercent > 0) {
            uint256 _gameFundSharedAmount = _amount.mul(gameFundSharedPercent).div(UNIT_ONE);
            IERC20(coin).transfer(gameFund, _gameFundSharedAmount);
            emit GameFundFunded(block.timestamp, _gameFundSharedAmount);
            _amount = _amount.sub(_gameFundSharedAmount);
        }
        IERC20(coin).safeApprove(boardroom, 0);
        IERC20(coin).safeApprove(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(block.timestamp, _amount);
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator
    {
        _updateCoinPrice();
        previousEpochPriceRatio = getPriceRatio();
        uint256 _coinPrice = getCoinPrice();
        uint256 _goldPrice = getGoldPrice();
        uint256 _seigniorageSaved = IERC20(coin).balanceOf(address(this));
        uint256 _coinSupply = IERC20(coin).totalSupply().sub(_seigniorageSaved);

        if (previousEpochPriceRatio > PRICE_RATIO_CEILING) {
            // Expansion
            uint256 _bondSupply = IERC20(bond).totalSupply();
            uint256 _expansionFactor = previousEpochPriceRatio.sub(UNIT_ONE);
            uint256 _savedForBond;
            uint256 _savedForBoardRoom;
            if (_seigniorageSaved >= _bondSupply) { // saved enough to pay dept
                if (_expansionFactor > MAX_EXPANSION_FACTOR) {
                    _expansionFactor = MAX_EXPANSION_FACTOR;
                }
                _savedForBoardRoom = _coinSupply.mul(_expansionFactor).div(UNIT_ONE);
            } else { // have not saved enough to pay dept
                if (_expansionFactor > MAX_EXPANSION_FACTOR) {
                    _expansionFactor = MAX_EXPANSION_FACTOR;
                }
                uint256 _seigniorage = _coinSupply.mul(_expansionFactor).div(UNIT_ONE);
                _savedForBoardRoom = _seigniorage.mul(SEIGNIORAGE_EXPANSION_FLOOR_FACTOR).div(UNIT_ONE);
                _savedForBond = _seigniorage.sub(_savedForBoardRoom);
            }
            if (_savedForBoardRoom > 0) {
                _sendToBoardRoom(_savedForBoardRoom);
            }
            if (_savedForBond > 0) {
                IMint(coin).mint(address(this), _savedForBond);
                emit TreasuryFunded(block.timestamp, _savedForBond);
            }
        }

        EpochRecord memory epochRecord = EpochRecord({
            time: block.number,
            rewardReceived: IBoardroom(boardroom).rewardReceived(),
            rewardPerShare: IBoardroom(boardroom).rewardPerShare(),
            bondCoinSpent: currentEpochBondCoinSpent,
            bondAmountBought: currentEpochBondAmountBought,
            bondCoinSupplied: currentEpochBondCoinSupplied,
            bondAmountRedeemed: currentEpochBondAmountRedeemed,
            coinPrice: _coinPrice,
            goldPrice: _goldPrice,
            priceRatio: previousEpochPriceRatio
            });
        epochRecords.push(epochRecord);

        currentEpochBondCoinSpent = 0;
        currentEpochBondAmountBought = 0;
        currentEpochBondCoinSupplied = 0;
        currentEpochBondAmountRedeemed = 0;
    }

    /* ========== BOARDROOM CONTROLLING FUNCTIONS ========== */

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator
    {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(address _token, uint256 _amount, address _to) external onlyOperator
    {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }

    /* ========== Recovery ========== */

    function recoverUnsupported(address _token, uint256 _amount, address _to) external onlyOperator
    {
        require(address(_token) != address(coin), "Treasury: cannot remove from reserves");
        IERC20(_token).transfer(_to, _amount);
    }
}