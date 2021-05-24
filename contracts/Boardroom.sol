// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/ITreasury.sol";
import "./utils/ContractGuard.sol";

contract ShareWrapper
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public share = IERC20(0xb0168Bca7dB2eFe53b9112c08aae36D744800645);

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256)
    {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256)
    {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual
    {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        share.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual
    {
        uint256 directorShare = _balances[msg.sender];
        require(directorShare >= amount, "Boardroom: withdraw request greater than staked amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = directorShare.sub(amount);
        share.safeTransfer(msg.sender, amount);
    }
}

contract Boardroom is ShareWrapper, ContractGuard
{
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Boardseat
    {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct BoardSnapshot
    {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========= CONSTANT VARIABLES ======== */

    // unit
    uint256 public constant UNIT_ONE = 1e18;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // core
    IERC20 public coin = IERC20(0x24eacCa1086F2904962a32732590F27Ca45D1d99);
    ITreasury public treasury = ITreasury(0x74606ae3185bB703Cb080A5057e797E25D0e79C1);

    mapping(address => Boardseat) public directors;
    BoardSnapshot[] public boardHistory;

    // protocol parameters
    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    constructor()
    {
        BoardSnapshot memory genesisSnapshot = BoardSnapshot({time: block.number, rewardReceived: 0, rewardPerShare: 0});
        boardHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 12; // Lock for 12 epochs (48h) before release withdraw
        rewardLockupEpochs = 3; // Lock for 3 epochs (12h) before release claimReward

        operator = msg.sender;
    }

    /* ========== EVENTS ========== */

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyOperator()
    {
        require(operator == msg.sender, "Boardroom: caller is not the operator");
        _;
    }

    modifier directorExists
    {
        require(balanceOf(msg.sender) > 0, "Boardroom: The director does not exist");
        _;
    }

    modifier updateReward(address director)
    {
        if (director != address(0))
        {
            Boardseat memory seat = directors[director];
            seat.rewardEarned = earned(director);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            directors[director] = seat;
        }
        _;
    }

    /* ========== GOVERNANCE ========== */

    function setOperator(address _operator) external onlyOperator
    {
        operator = _operator;
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator
    {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 84, "Boardroom: out of range"); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256)
    {
        return boardHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (BoardSnapshot memory)
    {
        return boardHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address director) public view returns (uint256)
    {
        return directors[director].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address director) internal view returns (BoardSnapshot memory)
    {
        return boardHistory[getLastSnapshotIndexOf(director)];
    }

    // =========== Epoch getters

    function canWithdraw(address director) external view returns (bool)
    {
        return directors[director].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function canClaimReward(address director) external view returns (bool) {
        return directors[director].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch();
    }

    function epoch() external view returns (uint256)
    {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256)
    {
        return treasury.nextEpochPoint();
    }

    function getPriceRatio() external view returns (uint256)
    {
        return treasury.getPriceRatio();
    }

    // =========== Reward getters

    function rewardReceived() public view returns (uint256)
    {
        return getLatestSnapshot().rewardReceived;
    }

    function rewardPerShare() public view returns (uint256)
    {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address director) public view returns (uint256)
    {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(director).rewardPerShare;

        return balanceOf(director).mul(latestRPS.sub(storedRPS)).div(UNIT_ONE).add(directors[director].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 _amount) public override onlyOneBlock updateReward(msg.sender)
    {
        require(_amount > 0, "Boardroom: Cannot stake 0");
        super.stake(_amount);
        directors[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
        emit Staked(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) public override onlyOneBlock directorExists updateReward(msg.sender)
    {
        require(_amount > 0, "Boardroom: Cannot withdraw 0");
        require(directors[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch(), "Boardroom: still in withdraw lockup");
        claimReward();
        super.withdraw(_amount);
        emit Withdrawn(msg.sender, _amount);
    }

    function exit() external
    {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public updateReward(msg.sender)
    {
        uint256 reward = directors[msg.sender].rewardEarned;
        if (reward > 0)
        {
            require(directors[msg.sender].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch(), "Boardroom: still in reward lockup");
            directors[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            directors[msg.sender].rewardEarned = 0;
            coin.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function allocateSeigniorage(uint256 _amount) external onlyOneBlock onlyOperator
    {
        require(_amount > 0, "Boardroom: Cannot allocate 0");
        require(totalSupply() > 0, "Boardroom: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(_amount.mul(UNIT_ONE).div(totalSupply()));

        BoardSnapshot memory newSnapshot = BoardSnapshot({time: block.number, rewardReceived: _amount, rewardPerShare: nextRPS});
        boardHistory.push(newSnapshot);

        coin.safeTransferFrom(msg.sender, address(this), _amount);
        emit RewardAdded(msg.sender, _amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator
    {
        // do not allow to drain core tokens
        require(address(_token) != address(coin), "coin");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }
}