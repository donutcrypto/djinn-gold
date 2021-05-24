// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract CoinRewardPool
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== DATA STRUCTURES ========== */

    struct UserInfo
    {
        uint256 amount; // How many tokens the user has provided.
        uint256 payoutOffset; // The rewards if the user deposited the current amount since the beginning of the pool.
    }

    struct PoolInfo
    {
        IERC20 token; // Address of token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool.
        uint256 lastRewardBlock; // Last block number that distribution occurs.
        uint256 accumulatedRewardPerToken; // Accumulated coins per token.
        bool isStarted; // if lastRewardBlock has passed
        uint256 feeFactor; // cost to deposit
        uint256 devFee; // fee for dev to collect
    }

    /* ========= CONSTANT VARIABLES ======== */

    // unit
    uint256 public constant UNIT_ONE = 1e18;

    uint256 public constant TOTAL_REWARDS = 9072 ether;

    uint256 public constant BLOCKS_PER_DAY = 28800; // 86400/3
    uint256 public constant RUNNING_BLOCKS = 201600; // 7 days = (86400/3) * 7 = 201600

    uint256 public COIN_PER_BLOCK = 0.045 ether;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;
    address public devAddress;

    IERC20 public coin = IERC20(0x24eacCa1086F2904962a32732590F27Ca45D1d99);

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    uint256 public totalAllocPoint = 0; // Must be the sum of all allocation points in all started pools.

    // epoch
    uint256 public startBlock;
    uint256 public endBlock;

    constructor()
    {
        startBlock = 6235797; // approx. 2021-04-03 00:00:00
        endBlock = startBlock.add(RUNNING_BLOCKS);

        operator = msg.sender;
    }

    /* =================== Events =================== */

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    /* =================== Modifier =================== */

    modifier onlyOperator()
    {
        require(operator == msg.sender, "CoinRewardPool: caller is not the operator");
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _from, uint256 _to) public view returns (uint256)
    {
        _from = Math.max(_from, startBlock);
        _to = Math.min(_to, endBlock);

        if (_from >= _to) return 0;

        return _to.sub(_from).mul(COIN_PER_BLOCK);
    }

    // View function to see pending rewards on frontend.
    function pendingRewards(uint256 _poolId, address _user) external view returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_poolId];
        UserInfo storage user = userInfo[_poolId][_user];

        uint256 accumulatedRewardPerToken = pool.accumulatedRewardPerToken;
        uint256 tokenSupply = pool.token.balanceOf(address(this));

        if (block.number > pool.lastRewardBlock && tokenSupply != 0)
        {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardBlock, block.number);
            uint256 _allocatedReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accumulatedRewardPerToken = accumulatedRewardPerToken.add(_allocatedReward.mul(UNIT_ONE).div(tokenSupply));
        }
        return user.amount.mul(accumulatedRewardPerToken).div(UNIT_ONE).sub(user.payoutOffset);
    }

    /* ========== SETUP FUNCTIONS ========== */

    function checkPoolDuplicate(IERC20 _token) internal view
    {
        uint256 _poolCount = poolInfo.length;
        for (uint256 poolId = 0; poolId < _poolCount; ++poolId)
        {
            require(poolInfo[poolId].token != _token, "CoinRewardPool: pool already exists");
        }
    }

    function addPool(uint256 _allocPoint, IERC20 _token, bool _withUpdate, uint256 _lastRewardBlock, uint256 _feeFactor) public onlyOperator
    {
        checkPoolDuplicate(_token);

        if (_withUpdate)
        {
            massUpdatePools();
        }

        if (block.number < startBlock)
        {
            // rewards haven't started yet
            if (_lastRewardBlock == 0 || _lastRewardBlock < startBlock)
            {
                _lastRewardBlock = startBlock;
            }
        }
        else
        {
            if (_lastRewardBlock == 0 || _lastRewardBlock < block.number)
            {
                _lastRewardBlock = block.number;
            }
        }

        bool _isStarted =
            (_lastRewardBlock <= startBlock) ||
            (_lastRewardBlock <= block.number);

        poolInfo.push(PoolInfo({
            token : _token,
            allocPoint : _allocPoint,
            lastRewardBlock : _lastRewardBlock,
            accumulatedRewardPerToken : 0,
            isStarted : _isStarted,
            feeFactor: _feeFactor,
            devFee: 0
            }));

        if (_isStarted)
        {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    function setPoolAllocPoints(uint256 _poolId, uint256 _allocPoint) public onlyOperator
    {
        massUpdatePools();

        PoolInfo storage pool = poolInfo[_poolId];

        if (pool.isStarted)
        {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;
    }

    function massUpdatePools() public
    {
        uint256 _poolCount = poolInfo.length;
        for (uint256 _poolId = 0; _poolId < _poolCount; ++_poolId)
        {
            updatePool(_poolId);
        }
    }

    function updatePool(uint256 _poolId) public
    {
        PoolInfo storage pool = poolInfo[_poolId];
        if (block.number <= pool.lastRewardBlock)
        {
            // pool hasn't started yet
            return;
        }

        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0)
        {
            pool.lastRewardBlock = block.number;
            return;
        }

        if (!pool.isStarted)
        {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }

        if (totalAllocPoint > 0)
        {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardBlock, block.number);
            uint256 _allocatedReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accumulatedRewardPerToken = pool.accumulatedRewardPerToken.add(_allocatedReward.mul(UNIT_ONE).div(tokenSupply));
        }

        pool.lastRewardBlock = block.number;
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setDevAddress(address _devAddress) external onlyOperator {
        devAddress = _devAddress;
    }

    function sendDevFee(uint256 _poolId) external {
        PoolInfo storage pool = poolInfo[_poolId];
        pool.token.safeTransfer(devAddress, pool.devFee);
        pool.devFee = 0;
    }

    /* ========== USER FUNCTIONS ========== */

    function depositTokens(uint256 _poolId, uint256 _amount) public
    {
        address _sender = msg.sender;

        PoolInfo storage pool = poolInfo[_poolId];
        UserInfo storage user = userInfo[_poolId][_sender];

        updatePool(_poolId);

        if (user.amount > 0)
        {
            uint256 _pending = user.amount.mul(pool.accumulatedRewardPerToken).div(UNIT_ONE).sub(user.payoutOffset);
            if (_pending > 0)
            {
                safePayout(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }

        if (_amount > 0)
        {
            pool.token.safeTransferFrom(_sender, address(this), _amount);

            if (pool.feeFactor > 0)
            {
                uint256 _fee = _amount.mul(pool.feeFactor).div(UNIT_ONE);

                pool.devFee = pool.devFee.add(_fee);
                user.amount = user.amount.add(_amount.sub(_fee));
            }
            else
            {
                user.amount = user.amount.add(_amount);
            }
        }

        user.payoutOffset = user.amount.mul(pool.accumulatedRewardPerToken).div(UNIT_ONE);
        emit Deposit(_sender, _poolId, _amount);
    }

    function withdraw(uint256 _poolId, uint256 _amount) public
    {
        address _sender = msg.sender;

        PoolInfo storage pool = poolInfo[_poolId];
        UserInfo storage user = userInfo[_poolId][_sender];

        require(user.amount >= _amount, "CoinRewardPool: withdrawing more than user deposit");

        updatePool(_poolId);

        uint256 _pending = user.amount.mul(pool.accumulatedRewardPerToken).div(UNIT_ONE).sub(user.payoutOffset);
        if (_pending > 0) {
            safePayout(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }

        user.payoutOffset = user.amount.mul(pool.accumulatedRewardPerToken).div(UNIT_ONE);
        emit Withdraw(_sender, _poolId, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _poolId) public
    {
        PoolInfo storage pool = poolInfo[_poolId];
        UserInfo storage user = userInfo[_poolId][msg.sender];

        uint256 _amount = user.amount;
        user.amount = 0;
        user.payoutOffset = 0;

        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _poolId, _amount);
    }

    // Safe payout function, just in case if rounding error causes pool to not have enough balance.
    function safePayout(address _to, uint256 _amount) internal
    {
        uint256 _coinBalance = coin.balanceOf(address(this));
        if (_coinBalance > 0)
        {
            _amount = Math.min(_amount,_coinBalance);
            coin.safeTransfer(_to, _amount);
        }
    }
}