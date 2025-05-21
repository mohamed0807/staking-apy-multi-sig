// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

error Staking__InvalidInput(string reason);
error Staking__ActionNotAllowed(string reason);
error Staking__TransferFailed();

interface IERC20WithDecimals is IERC20 {
    function decimals() external view returns (uint8);
}

contract Staking is Ownable, ReentrancyGuard {

    IERC20WithDecimals public stakingToken;

    uint256 public apy = 1000;
    uint256 public minimumStake;
    uint256 public stakingDuration = 30 days;
    uint256 public totalStaked;
    address internal multiSigWallet;

    struct StakeInfo {
        uint256 amount;
        uint256 stakedAt;
        uint256 lastClaimTime;
        bool active;
    }

    mapping(address => StakeInfo) public stakes;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event APYUpdated(uint256 newAPY);

    constructor(
        address _stakingToken,
        uint256 _minimumStake,
        address _multiSigWallet
    ) Ownable(msg.sender) {
        if (_stakingToken == address(0) ||_multiSigWallet == address(0)) {
            revert Staking__InvalidInput("Invalid address");
        }
        if (_minimumStake <= 0) {
            revert Staking__InvalidInput(
                "Minimum stake must be greater than 0"
            );
        }
        
        stakingToken = IERC20WithDecimals(_stakingToken);
        multiSigWallet = _multiSigWallet;
        minimumStake = _minimumStake * 10 ** stakingToken.decimals();
    }

    function updateAPY(uint256 _apy) external onlyOwner {
        if (_apy <= 0) {
            revert Staking__InvalidInput("APY must be greater than 0");
        }

        apy = _apy;
        emit APYUpdated(_apy);
    }

    function updateMinimumStake(uint256 _minimumStake) external onlyOwner {
        if (_minimumStake <= 0) {
            revert Staking__InvalidInput(
                "Minimum stake must be greater than 0"
            );
        }
        minimumStake = _minimumStake * 10 ** stakingToken.decimals();
    }

    function updateStakingDuration(
        uint256 _stakingDuration
    ) external onlyOwner {
        stakingDuration = _stakingDuration;
    }

    function stake(uint256 _amount) external nonReentrant {
        _amount = _amount * 10 ** stakingToken.decimals();
        if (_amount <= 0) {
            revert Staking__InvalidInput(
                "Amount must be greater than 0"
            );
        }

        if (_amount < minimumStake) {
            revert Staking__InvalidInput(
                "Amount must be greater than minimum stake"
            );
        }

        bool success = stakingToken.transferFrom(
            msg.sender,
            address(this),
            _amount
        );
        if (!success) {
            revert Staking__TransferFailed();
        }

        if (stakes[msg.sender].active) {
            claimReward();
            stakes[msg.sender].amount += _amount;
        } else {
            stakes[msg.sender] = StakeInfo({
                amount: _amount,
                stakedAt: block.timestamp,
                lastClaimTime: block.timestamp,
                active: true
            });
        }

        totalStaked += _amount;
        emit Staked(msg.sender, _amount);
    }

    function unstake() external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];

        if (!userStake.active) {
            revert Staking__ActionNotAllowed("No active stake");
        }

        uint256 totalDuration = userStake.stakedAt + stakingDuration;

        if (block.timestamp < totalDuration) {
            revert Staking__ActionNotAllowed(
                "Staking period not completed"
            );
        }

        uint256 amount = userStake.amount;

        claimReward();

        userStake.amount = 0;
        userStake.active = false;

        totalStaked -= amount;

        bool success = stakingToken.transfer(msg.sender, amount);

        if (!success) {
            revert Staking__TransferFailed();
        }

        emit Unstaked(msg.sender, amount);
    }

    function claimReward() public nonReentrant returns (uint256) {
        StakeInfo storage userStake = stakes[msg.sender];

        if (!userStake.active) {
            revert Staking__ActionNotAllowed("No active stake");
        }

        uint256 totalDuration = userStake.stakedAt + stakingDuration;

        if (block.timestamp < totalDuration) {
            revert Staking__ActionNotAllowed(
                "Staking period not completed"
            );
        }

        uint256 reward = calculateReward(msg.sender);
        if (reward > 0) {
            userStake.lastClaimTime = block.timestamp;

            bool success = stakingToken.transfer(msg.sender, reward);
            if (!success) {
                revert Staking__TransferFailed();
            }

            emit RewardClaimed(msg.sender, reward);
        }

        return reward;
    }

    function calculateReward(address _user) public view returns (uint256) {
        StakeInfo memory userStake = stakes[_user];
        if (!userStake.active) {
            return 0;           
        }
        uint256 timeElapsed = block.timestamp - userStake.lastClaimTime;

        uint256 reward = (userStake.amount * apy * timeElapsed) / 365 days;
        reward = reward / 10000;

        return reward;
    }
    function getStakeInfo(
        address _user
    )
        external
        view
        returns (
            uint256 amount,
            uint256 stakedAt,
            uint256 lastClaimTime,
            bool active,
            uint256 availableReward,
            uint256 remainingTime
        )
    {
        StakeInfo memory userStake = stakes[_user];
        uint256 endTime = userStake.stakedAt + stakingDuration;

        uint256 endTimeSubWithCurrentTime = endTime - block.timestamp;

        uint256 remaining = block.timestamp >= endTime
            ? 0
            : endTimeSubWithCurrentTime;

        return (
            userStake.amount,
            userStake.stakedAt,
            userStake.lastClaimTime,
            userStake.active,
            calculateReward(_user),
            remaining
        );
    }

    function withdraw(address _token) external {
        onlyMultiSigWallet();
        if (
            _token == address(0) ||
            _token == address(stakingToken) ||
            _token == address(this)
        ) {
            revert Staking__InvalidInput("Invalid token address");
        }

        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));

        bool success = token.transfer(owner(), balance);
        if (!success) {
            revert Staking__TransferFailed();
        }
    }

    function onlyMultiSigWallet() internal view {
        if (msg.sender != multiSigWallet) {
            revert Staking__ActionNotAllowed("Only multi-sig wallet can call this function");
        }
    }
}

 