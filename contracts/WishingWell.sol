// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract WishingWell
{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    /* ========= CONSTANT VARIABLES ======== */

    // unit
    uint256 public constant UNIT_ONE = 1e18;

    // wish
    address public TOKEN = address(0x24eacCa1086F2904962a32732590F27Ca45D1d99);

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;
    address public randomizer;
    address public projectAddress = address(0x7ba6d610Da4841758E993733b7562158b52a16F5);

    // rules
    uint256 public ruleBonusFactor = 2000e14; // a factor on the game's balance to add as a bonus prize each round
    uint256 public ruleWishCost = 500e14; // the cost to make a wish
    uint256 public ruleMaximumBalance = 0; // if non-zero, balance exceeding this will be taken as profit

    uint256 public ruleInitialRoundDuration = 86400; // rounds start with this number of seconds on the clock
    uint256 public ruleMaxRoundDuration = 86400; // maximum number of seconds on the clock

    uint256 public ruleSmallRoundSize = 100; // rounds with fewer wishes than this are considered small
    uint256 public ruleSmallRoundExtraDuration = 1800; // in small rounds, wishes add this number of seconds to the clock
    uint256 public ruleBigRoundExtraDuration = 300; // in big rounds, wishes add this number of seconds to the clock

    // rounds
    uint256 public currentRoundId;
    bool public currentRoundStarted;

    uint256 public currentRoundOpenTime;
    uint256 public currentRoundPot;
    uint256 public currentRoundBonus;
    uint256 public currentRoundCloseTime;

    // states
    // each round has 4 states
    //   pre-game: currentRoundStarted is false
    //   open: currentRoundStarted is true and block.timestamp < getCurrentRoundCloseTime()
    //   closed: currentRoundStarted is true and getCurrentRoundCloseTime() <= block.timestamp
    //   ended: currentRoundId != roundId

    // a round is considered active if it is open or closed, but not in pre-game or ended
    // rules are only allowed to change if there are no active rounds

    // wishes
    // these are indexed from 1, 0 is interpretted as 'null'
    mapping(uint256 => uint256) roundWishCount;
    mapping(uint256 => mapping(uint256 => uint256)) roundWishAmountss;
    mapping(uint256 => mapping(uint256 => address)) roundWishUserss;
    mapping(uint256 => mapping(address => uint256[])) roundUserWishIdss;

    // book keeping
    mapping(uint256 => mapping(uint256 => uint256)) roundWishPrevIdss;
    mapping(uint256 => mapping(uint256 => uint256)) roundWishNextIdss;
    mapping(uint256 => uint256) roundRootIds;
    mapping(uint256 => mapping(uint256 => uint256)) roundWishLeftIdss;
    mapping(uint256 => mapping(uint256 => uint256)) roundWishRghtIdss;

    // records
    mapping(uint256 => uint256) pastRoundOpenTimes;
    mapping(uint256 => uint256) pastRoundCloseTimes;
    mapping(uint256 => uint256) pastRoundMaxPrizes;
    mapping(uint256 => uint256) pastRoundGrantedId;
    mapping(uint256 => uint256) pastRoundGrantedAmount;
    mapping(uint256 => address) pastRoundGrantedUser;
    mapping(uint256 => uint256) pastRoundPrizes;

    constructor()
    {
        operator = msg.sender;
        randomizer = msg.sender; // to be replaced with a caller to chainlink
    }

    /* =================== Events =================== */

    event RoundStarted(uint256 indexed roundId);
    event WishMade(uint256 indexed roundId, uint256 indexed wishId, address indexed user, uint256 amount);
    event WishGranted(uint256 indexed roundId, uint256 indexed wishId, address indexed user, uint256 amount, uint256 rolled);
    event NoWishGranted(uint256 indexed roundId, uint256 rolled);
    event RoundEnded(uint256 indexed roundId);

    /* =================== Modifier =================== */

    modifier onlyOperator()
    {
        require(operator == msg.sender, "WishingWell: caller is not the operator");
        _;
    }

    modifier onlyRandomizer()
    {
        require(randomizer == msg.sender, "WishingWell: caller is not the randomizer");
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // round timing

    function roundActive() public view returns (bool)
    {
        return currentRoundStarted && !getCurrentRoundClosed();
    }

    function getCurrentRoundClosed() public view returns (bool)
    {
        return currentRoundCloseTime <= block.timestamp;
    }

    function getCurrentRoundExtraDuration() public view returns (uint256)
    {
        if (getCurrentRoundSmall())
        {
            return ruleSmallRoundExtraDuration;
        }
        else
        {
            return ruleBigRoundExtraDuration;
        }
    }

    function getCurrentRoundSmall() public view returns (bool)
    {
        return getCurrentWishCount() < ruleSmallRoundSize;
    }

    // current round

    function getCurrentMaxPrize() public view returns (uint256)
    {
        return currentRoundPot.add(currentRoundBonus);
    }

    function getCurrentWishCount() public view returns (uint256)
    {
        return roundWishCount[currentRoundId];
    }

    function getCurrentWishAmount(uint256 _wishId) public view returns (uint256)
    {
        return roundWishAmountss[currentRoundId][_wishId];
    }

    function getCurrentWishUser(uint256 _wishId) public view returns (address)
    {
        return roundWishUserss[currentRoundId][_wishId];
    }

    function getCurrentUserWishIds(address _user) public view returns (uint256[] memory)
    {
        return roundUserWishIdss[currentRoundId][_user];
    }

    function getCurrentLowestWishId() public view returns (uint256)
    {
        return roundWishNextIdss[currentRoundId][0];
    }

    function getCurrentHighestWishId() public view returns (uint256)
    {
        return roundWishPrevIdss[currentRoundId][0];
    }

    function getCurrentNextWishId(uint256 _wishId) public view returns (uint256)
    {
        return roundWishNextIdss[currentRoundId][_wishId];
    }

    function getCurrentPrevWishId(uint256 _wishId) public view returns (uint256)
    {
        return roundWishPrevIdss[currentRoundId][_wishId];
    }

    // past rounds

    function getRoundWishCount(uint256 _roundId) public view returns (uint256)
    {
        return roundWishCount[_roundId];
    }

    function getRoundWishAmount(uint256 _roundId, uint256 _wishId) public view returns (uint256)
    {
        return roundWishAmountss[_roundId][_wishId];
    }

    function getRoundWishUser(uint256 _roundId, uint256 _wishId) public view returns (address)
    {
        return roundWishUserss[_roundId][_wishId];
    }

    function getRoundUserWishIds(uint256 _roundId, address _user) public view returns (uint256[] memory)
    {
        return roundUserWishIdss[_roundId][_user];
    }

    function getRoundLowestWishId(uint256 _roundId) public view returns (uint256)
    {
        return roundWishNextIdss[_roundId][0];
    }

    function getRoundHighestWishId(uint256 _roundId) public view returns (uint256)
    {
        return roundWishPrevIdss[_roundId][0];
    }

    function getRoundNextWishId(uint256 _roundId, uint256 _wishId) public view returns (uint256)
    {
        return roundWishNextIdss[_roundId][_wishId];
    }

    function getRoundPrevWishId(uint256 _roundId, uint256 _wishId) public view returns (uint256)
    {
        return roundWishPrevIdss[_roundId][_wishId];
    }

    // records

    function getRoundOpenTime(uint256 _roundId) public view returns (uint256)
    {
        return pastRoundOpenTimes[_roundId];
    }

    function getRoundCloseTime(uint256 _roundId) public view returns (uint256)
    {
        return pastRoundCloseTimes[_roundId];
    }

    function getRoundMaxPrize(uint256 _roundId) public view returns (uint256)
    {
        return pastRoundMaxPrizes[_roundId];
    }

    function getRoundGrantedId(uint256 _roundId) public view returns (uint256)
    {
        return pastRoundGrantedId[_roundId];
    }

    function getRoundGrantedAmount(uint256 _roundId) public view returns (uint256)
    {
        return pastRoundGrantedAmount[_roundId];
    }

    function getRoundGrantedUser(uint256 _roundId) public view returns (address)
    {
        return pastRoundGrantedUser[_roundId];
    }

    function getRoundPrize(uint256 _roundId) public view returns (uint256)
    {
        return pastRoundPrizes[_roundId];
    }

    /* ========== USER FUNCTIONS ========== */

    function makeWish(uint256 _amount) external
    {
        require(currentRoundStarted, "WishingWell: round hasn't started yet");
        require(!getCurrentRoundClosed(), "WishingWell: round has ended");

        address _user = msg.sender;

        IERC20(TOKEN).safeTransferFrom(_user, address(this), ruleWishCost);

        // wish id
        roundWishCount[currentRoundId] = roundWishCount[currentRoundId].add(1);
        uint256 _wishId = roundWishCount[currentRoundId];

        // add wish
        roundWishAmountss[currentRoundId][_wishId] = _amount;
        roundWishUserss[currentRoundId][_wishId] = _user;

        currentRoundPot = currentRoundPot.add(ruleWishCost);

        // add to user
        mapping(address => uint256[]) storage userWishIds = roundUserWishIdss[currentRoundId];
        userWishIds[_user].push(_wishId);

        // add to book keeping
        wishInsertBookkeeping(_wishId); // this also checks that there are no duplicate wishes

        // update timing
        currentRoundCloseTime = Math.min(
            block.timestamp.add(ruleMaxRoundDuration),
            currentRoundCloseTime.add(getCurrentRoundExtraDuration())
            );

        emit WishMade(currentRoundId, _wishId, _user, _amount);
    }

    /* ========== OPERATOR FUNCTIONS ========== */

    function setOperator(address _operator) external onlyOperator
    {
        operator = _operator;
    }

    function setRandomizer(address _randomizer) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        randomizer = _randomizer;
    }

    function setProjectAddress(address _projectAddress) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        projectAddress = _projectAddress;
    }

    function closeGame() external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        // extract remaining balance
        uint256 _balance = IERC20(TOKEN).balanceOf(address(this));
        IERC20(TOKEN).safeTransfer(projectAddress, _balance);
    }

    function recoverUnsupported(address _token, uint256 _amount, address _to) external onlyOperator
    {
        require(_token != TOKEN, "WishingWell: cannot recover game token");
        IERC20(_token).transfer(_to, _amount);
    }

    /* ========== RANDOMIZER FUNCTIONS ========== */

    function startRound() public onlyRandomizer
    {
        require(!currentRoundStarted, "WishingWell: round already started");

        // reset things
        currentRoundOpenTime = block.timestamp;
        currentRoundPot = 0;
        currentRoundBonus = IERC20(TOKEN).balanceOf(address(this)).mul(ruleBonusFactor).div(UNIT_ONE);
        currentRoundCloseTime = block.timestamp.add(ruleInitialRoundDuration);

        emit RoundStarted(currentRoundId);
        currentRoundStarted = true;
    }

    function endRound(uint256 _seed) public onlyRandomizer
    {
        require(currentRoundStarted, "WishingWell: round hasn't started yet");
        require(getCurrentRoundClosed(), "WishingWell: round is still open");

        currentRoundStarted = false;

        if (getCurrentWishCount() == 0) // :(
        {
            pastRoundOpenTimes[currentRoundId] = currentRoundOpenTime;
            pastRoundCloseTimes[currentRoundId] = currentRoundCloseTime;

            pastRoundMaxPrizes[currentRoundId] = getCurrentMaxPrize();

            emit RoundEnded(currentRoundId);
            currentRoundId = currentRoundId.add(1);
            return;
        }

        // calculate payout
        // currently this relies on the caller's randomness. to be upgraded to chainlink when available
        uint256 _roll = uint256(keccak256(abi.encodePacked(_seed)));
        uint256 _maxPrize = getCurrentMaxPrize();

        uint256 _prize = _roll.mod(_maxPrize);

        // determine winner
        uint256 _winnerId = getPrevWishId(_prize);
        if (_winnerId == 0)
        {
            pastRoundOpenTimes[currentRoundId] = currentRoundOpenTime;
            pastRoundCloseTimes[currentRoundId] = currentRoundCloseTime;

            pastRoundMaxPrizes[currentRoundId] = _maxPrize;
            pastRoundGrantedId[currentRoundId] = 0;
            pastRoundGrantedAmount[currentRoundId] = 0;
            pastRoundGrantedUser[currentRoundId] = address(0);
            pastRoundPrizes[currentRoundId] = _prize;

            emit NoWishGranted(currentRoundId, _prize);
        }
        else
        {
            address _winnerUser = getCurrentWishUser(_winnerId);
            uint256 _winnerAmount = getCurrentWishAmount(_winnerId);

            // add to records record
            pastRoundOpenTimes[currentRoundId] = currentRoundOpenTime;
            pastRoundCloseTimes[currentRoundId] = currentRoundCloseTime;

            pastRoundMaxPrizes[currentRoundId] = _maxPrize;
            pastRoundGrantedId[currentRoundId] = _winnerId;
            pastRoundGrantedAmount[currentRoundId] = _winnerAmount;
            pastRoundGrantedUser[currentRoundId] = _winnerUser;
            pastRoundPrizes[currentRoundId] = _prize;

            // pay winner
            safePayout(_winnerUser, _winnerAmount);
            emit WishGranted(currentRoundId, _winnerId, _winnerUser, _winnerAmount, _prize);

            // prize comes from pot first
            // if any thing from the pot remains, send half of it to the project address and save the rest for future bonuses
            if (_prize < currentRoundPot)
            {
                safePayout(projectAddress, currentRoundPot.sub(_prize).div(2));
            }
        }

        // take excess balance as profit
        uint256 _balance = IERC20(TOKEN).balanceOf(address(this));
        if (ruleMaximumBalance != 0 && ruleMaximumBalance < _balance)
        {
            safePayout(projectAddress, _balance.sub(ruleMaximumBalance));
        }

        // advance to next round
        emit RoundEnded(currentRoundId);
        currentRoundId = currentRoundId.add(1);
    }

    function endRoundAndStartNext(uint256 _seed) external onlyRandomizer
    {
        endRound(_seed);
        startRound();
    }

    /* ========== RULE UPDATE FUNCTIONS ========== */

    function setRuleBonusFactor(uint256 _ruleBonusFactor) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        ruleBonusFactor = _ruleBonusFactor;
    }

    function setRuleWishCost(uint256 _ruleWishCost) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        ruleWishCost = _ruleWishCost;
    }

    function setRuleMaximumBalance(uint256 _ruleMaximumBalance) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        ruleMaximumBalance = _ruleMaximumBalance;
    }

    function setRuleInitialRoundDuration(uint _ruleInitialRoundDuration) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        ruleInitialRoundDuration = _ruleInitialRoundDuration;
    }

    function setRuleMaxRoundDuration(uint _ruleMaxRoundDuration) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        ruleMaxRoundDuration = _ruleMaxRoundDuration;
    }

    function setRuleSmallRoundSize(uint256 _ruleSmallRoundSize) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        ruleSmallRoundSize = _ruleSmallRoundSize;
    }

    function setRuleSmallRoundExtraDuration(uint256 _ruleSmallRoundExtraDuration) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        ruleSmallRoundExtraDuration = _ruleSmallRoundExtraDuration;
    }

    function setRuleBigRoundExtraDuration(uint256 _ruleBigRoundExtraDuration) external onlyOperator
    {
        require(!roundActive(), "WishingWell: game is still active");
        ruleBigRoundExtraDuration = _ruleBigRoundExtraDuration;
    }

    /* ========== INTERNAL VIEW FUNCTIONS ========== */

    function getPrevWishId(uint256 _amount) internal view returns (uint256)
    {
        uint256 _currId = roundRootIds[currentRoundId];
        if (_currId == 0)
        {
            return 0;
        }

        mapping(uint256 => uint256) storage wishAmounts = roundWishAmountss[currentRoundId];

        mapping(uint256 => uint256) storage wishPrevIds = roundWishPrevIdss[currentRoundId];
        mapping(uint256 => uint256) storage wishNextIds = roundWishNextIdss[currentRoundId];
        mapping(uint256 => uint256) storage wishLeftIds = roundWishLeftIdss[currentRoundId];
        mapping(uint256 => uint256) storage wishRghtIds = roundWishRghtIdss[currentRoundId];

        while (_currId != 0)
        {
            if (_amount <= wishAmounts[_currId])
            {
                if (wishLeftIds[_currId] != 0)
                {
                    _currId = wishLeftIds[_currId];
                }
                else
                {
                    return wishPrevIds[_currId];
                }
            }
            else
            {
                if (wishRghtIds[_currId] != 0)
                {
                    _currId = wishRghtIds[_currId];
                }
                else
                {
                    return _currId;
                }
            }
        }

        return 0;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    // Safe payout function, just in case if rounding error causes pool to not have enough balance.
    function safePayout(address _to, uint256 _amount) internal
    {
        uint256 _balance = IERC20(TOKEN).balanceOf(address(this));
        if (_balance > 0)
        {
            _amount = Math.min(_amount,_balance);
            IERC20(TOKEN).safeTransfer(_to, _amount);
        }
    }

    function wishInsertBookkeeping(uint256 _wishId) internal
    {
        uint256 _currId = roundRootIds[currentRoundId];
        if (_currId == 0)
        {
            roundRootIds[currentRoundId] = _wishId;
            roundWishPrevIdss[currentRoundId][0] = _wishId;
            roundWishNextIdss[currentRoundId][0] = _wishId;
            return;
        }

        mapping(uint256 => uint256) storage wishAmounts = roundWishAmountss[currentRoundId];

        uint256 _amount = wishAmounts[_wishId];

        mapping(uint256 => uint256) storage wishPrevIds = roundWishPrevIdss[currentRoundId];
        mapping(uint256 => uint256) storage wishNextIds = roundWishNextIdss[currentRoundId];
        mapping(uint256 => uint256) storage wishLeftIds = roundWishLeftIdss[currentRoundId];
        mapping(uint256 => uint256) storage wishRghtIds = roundWishRghtIdss[currentRoundId];

        bool _found = false;

        while (!_found)
        {
            require(_amount != wishAmounts[_currId], "WishingWell: duplicate wish");

            if (_amount <= wishAmounts[_currId])
            {
                if (wishLeftIds[_currId] != 0)
                {
                    _currId = wishLeftIds[_currId];
                }
                else
                {
                    wishLeftIds[_currId] = _wishId;
                    _currId = wishPrevIds[_currId];

                    _found = true;
                }
            }
            else
            {
                if (wishRghtIds[_currId] != 0)
                {
                    _currId = wishRghtIds[_currId];
                }
                else
                {
                    wishRghtIds[_currId] = _wishId;

                    _found = true;
                }
            }
        }

        wishPrevIds[wishNextIds[_currId]] = _wishId;
        wishNextIds[_wishId] = wishNextIds[_currId];

        wishNextIds[_currId] = _wishId;
        wishPrevIds[_wishId] = _currId;
    }
}
