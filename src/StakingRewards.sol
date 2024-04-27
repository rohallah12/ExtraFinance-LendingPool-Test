//SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeMath} from "./library/SafeMath.sol";
import {Math} from "./library/Math.sol";

contract StakingRewards is Ownable(msg.sender) {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Reward {
        uint256 startTime;
        uint256 endTime;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    IERC20 public immutable stakedToken;
    address public immutable lendingPool;

    address[] public rewardTokens;

    mapping(address => bool) public inRewardsTokenList;

    uint256 public totalStaked;

    mapping(address => Reward) public rewardData;
    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256))
        public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public userRewardsClaimable;

    uint internal _unlocked = 1;

    modifier nonReentrant() {
        require(_unlocked == 1, "reentrant call");
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    modifier onlyLendingPool() {
        require(lendingPool == msg.sender);
        _;
    }

    modifier updateReward(address user) {
        for (uint i; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            rewardData[rewardToken].rewardPerTokenStored = rewardPerToken(
                rewardToken
            );
            rewardData[rewardToken].lastUpdateTime = Math.min(
                rewardData[rewardToken].endTime,
                block.timestamp
            );

            if (user != address(0)) {
                userRewardsClaimable[user][rewardToken] = earned(
                    user,
                    rewardToken,
                    rewardData[rewardToken].rewardPerTokenStored
                );
                userRewardPerTokenPaid[user][rewardToken] = rewardData[
                    rewardToken
                ].rewardPerTokenStored;
            }
        }
        _;
    }
    
    event RewardsSet(
        address rewardsToken,
        uint256 start,
        uint256 end,
        uint256 total
    );

    event Staked(
        address indexed user,
        address indexed onBehalfOf,
        uint256 amount
    );

    event Withdraw(address indexed user, address indexed to, uint256 amount);

    event RewardPaid(
        address indexed user,
        address indexed rewardsToken,
        uint256 claimed
    );

    /// @notice This contract must be create in lendingPool's `initReserve()`
    constructor(address _stakingToken) {
        stakedToken = IERC20(_stakingToken);
        lendingPool = msg.sender;
    }

    function rewardPerToken(address rewardToken) public view returns (uint) {
        if (block.timestamp <= rewardData[rewardToken].startTime) {
            // new rewards not start
            return rewardData[rewardToken].rewardPerTokenStored;
        }

        //@audit-info get the distance since last update
        uint256 dt = Math.min(
            rewardData[rewardToken].endTime,
            block.timestamp
        ) - (rewardData[rewardToken].lastUpdateTime);

        if (dt == 0 || totalStaked == 0) {
            return rewardData[rewardToken].rewardPerTokenStored;
        }

        return
            rewardData[rewardToken].rewardPerTokenStored +
            (rewardData[rewardToken].rewardRate * dt * 1e18) /
            totalStaked;
    }

    function earned(
        address user,
        address rewardToken
    ) public view returns (uint) {
        uint256 curRewardPerToken = rewardPerToken(rewardToken);

        return earned(user, rewardToken, curRewardPerToken);
    }

    function earned(
        address user,
        address rewardToken,
        uint256 curRewardPerToken
    ) internal view returns (uint) {
        uint256 d = curRewardPerToken -
            userRewardPerTokenPaid[user][rewardToken];

        return
            (balanceOf[user] * d) /
            1e18 +
            userRewardsClaimable[user][rewardToken];
    }

    function setReward(
        address rewardToken,
        uint256 startTime,
        uint256 endTime,
        uint256 totalRewards
    ) public onlyOwner nonReentrant updateReward(address(0)) {
        require(startTime < endTime, "start must lt end");
        require(rewardData[rewardToken].endTime < block.timestamp, "not end");

        if (!inRewardsTokenList[rewardToken]) {
            rewardTokens.push(rewardToken);
            inRewardsTokenList[rewardToken] = true;
        }

        rewardData[rewardToken].startTime = startTime;
        rewardData[rewardToken].endTime = endTime;
        rewardData[rewardToken].lastUpdateTime = block.timestamp;
        rewardData[rewardToken].rewardRate = //token per second
            totalRewards /
            (endTime - startTime);

        if (block.timestamp > startTime && totalStaked > 0) {
            uint256 dt = block.timestamp - startTime;

            //@audit-info some reward tokens may not have 18 decimals?
            rewardData[rewardToken].rewardPerTokenStored +=
                (rewardData[rewardToken].rewardRate * dt * 1e18) /
                totalStaked;
        }

        if (block.timestamp > startTime && totalStaked == 0) {
            // If this happens, there is no staked tokens from startTime to now
            // The rewards in this period should be removed
            uint256 dt = block.timestamp - startTime;
            totalRewards -= rewardData[rewardToken].rewardRate * dt;
        }

        IERC20(rewardToken).safeTransferFrom(
            msg.sender,
            address(this),
            totalRewards
        );

        emit RewardsSet(rewardToken, startTime, endTime, totalRewards);
    }

    /**
     * @dev Stake `amount` of assets to this contract
     * @param amount The amount of assets to be staked
     * @param onBehalfOf The address that will receive the staked position, same as msg.sender if the user
     *   wants to receive them on his own wallet.
     **/
    function stake(
        uint amount,
        address onBehalfOf
    ) external nonReentrant updateReward(onBehalfOf) {
        require(amount > 0, "amount = 0");

        stakedToken.safeTransferFrom(msg.sender, address(this), amount);

        balanceOf[onBehalfOf] += amount;
        totalStaked += amount;

        emit Staked(msg.sender, onBehalfOf, amount);
    }

    /**
     * @dev Withdraw `amount` of staked assets
     * @param amount The amount of assets to withdraw
     * @param to The address that will receive the staked assets, same as msg.sender if the user
     *   wants to receive them on his own wallet.
     **/
    function withdraw(
        uint amount,
        address to
    ) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount = 0");

        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;

        require(stakedToken.transfer(to, amount), "transfer failed");

        emit Withdraw(msg.sender, to, amount);
    }

    /**
     * @dev Withdraw `amount` of staked assets called by lendingPool
     * only lendingPool can call this function in `unstakeAndWithdraw()` of LendingPool
     * @param amount The amount of assets to withdraw
     * @param user The user of the staked position
     * @param to The address that will receive the staked assets, same as msg.sender if the user
     *   wants to receive them on his own wallet.
     **/
    function withdrawByLendingPool(
        uint amount,
        address user,
        address to
    ) external onlyLendingPool nonReentrant updateReward(user) {
        require(amount > 0, "amount = 0");

        balanceOf[user] -= amount;
        totalStaked -= amount;

        require(stakedToken.transfer(to, amount), "transfer falied");

        emit Withdraw(user, to, amount);
    }

    function claim() external nonReentrant updateReward(msg.sender) {
        for (uint i = 0; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            uint256 claimable = userRewardsClaimable[msg.sender][rewardToken];
            if (claimable > 0) {
                userRewardsClaimable[msg.sender][rewardToken] = 0;
                //@audit-info use safeTransfer, some reward tokens may not support this
                require(
                    IERC20(rewardToken).transfer(msg.sender, claimable),
                    "transfer failed"
                );
                emit RewardPaid(msg.sender, rewardToken, claimable);
            }
        }
    }

    function update() external updateReward(address(0)) onlyOwner {}

    function rewardsTokenListLength() external view returns (uint256) {
        return rewardTokens.length;
    }
}
