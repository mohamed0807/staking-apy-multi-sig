// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {Staking, Staking__InvalidInput, Staking__ActionNotAllowed} from "src/Staking.sol";
import {MockERC20} from "./MockERC20.sol";
import {MultiSigWallet} from "src/MultiSigWallet.sol";

contract StakingTest is Test {
    Staking public staking;
    MockERC20 public stakingToken;

    address public owner;
    address public user1;
    address public user2;

    address[] public owners;

    MultiSigWallet wallet;
    EntryPoint entryPoint;

    address owner1;
    address owner2;
    address owner3;

    uint256 pk1;
    uint256 pk2;
    uint256 pk3;

    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 public constant MINIMUM_STAKE = 100;
    uint256 public constant APY = 1000;
    uint256 public constant STAKING_DURATION = 30 days;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event APYUpdated(uint256 newAPY);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        pk1 = 0xA11CE;
        pk2 = 0xB0B;
        pk3 = 0xC0DE;
        owner1 = vm.addr(pk1);
        owner2 = vm.addr(pk2);
        owner3 = vm.addr(pk3);

        entryPoint = new EntryPoint();

        owners.push(owner1);
        owners.push(owner2);
        owners.push(owner3);

        wallet = new MultiSigWallet(owners, 2, address(entryPoint));

        stakingToken = new MockERC20("Staking Token", "STK", 18);
        stakingToken.mint(owner, INITIAL_SUPPLY);

        staking = new Staking(
            address(stakingToken),
            MINIMUM_STAKE,
            address(wallet)
        );

        stakingToken.transfer(user1, 10_000 ether);
        stakingToken.transfer(user2, 10_000 ether);
    }

    function test_Initialization() public view {
        assertEq(address(staking.stakingToken()), address(stakingToken));
        assertEq(staking.apy(), APY);
        assertEq(staking.minimumStake(), MINIMUM_STAKE * 10 ** 18);
        assertEq(staking.stakingDuration(), STAKING_DURATION);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.owner(), owner);
    }

    function test_UpdateAPY() public {
        uint256 newAPY = 1000;

        vm.expectEmit(true, true, true, true);
        emit APYUpdated(newAPY);
        staking.updateAPY(newAPY);

        assertEq(staking.apy(), newAPY);
    }

    function test_UpdateAPY_RevertIfZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Staking__InvalidInput.selector,
                "APY must be greater than 0"
            )
        );
        staking.updateAPY(0);
    }

    function test_UpdateMinimumStake() public {
        uint256 newMinimum = 200;
        staking.updateMinimumStake(newMinimum);

        assertEq(staking.minimumStake(), newMinimum * 10 ** 18);
    }

    function test_UpdateMinimumStake_RevertIfZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Staking__InvalidInput.selector,
                "Minimum stake must be greater than 0"
            )
        );
        staking.updateMinimumStake(0);
    }

    function test_UpdateStakingDuration() public {
        uint256 newDuration = 60 days;
        staking.updateStakingDuration(newDuration);

        assertEq(staking.stakingDuration(), newDuration);
    }

    function test_Stake() public {
        uint256 stakeAmount = 500;
        uint256 stakeAmountWithDecimals = stakeAmount * 10 ** 18;

        vm.startPrank(user1);

        stakingToken.approve(address(staking), stakeAmountWithDecimals);

        vm.expectEmit(true, true, true, true);
        emit Staked(user1, stakeAmountWithDecimals);

        console.log("Staking %s tokens", stakeAmount);

        staking.stake(stakeAmount);

        vm.stopPrank();

        (
            uint256 amount,
            uint256 stakedAt,
            uint256 lastClaimTime,
            bool active,
            ,

        ) = staking.getStakeInfo(user1);

        assertEq(amount, stakeAmountWithDecimals);
        assertEq(stakedAt, block.timestamp);
        assertEq(lastClaimTime, block.timestamp);
        assertTrue(active);
        assertEq(staking.totalStaked(), stakeAmountWithDecimals);
    }

    function test_Stake_RevertIfAmountTooLow() public {
        uint256 stakeAmount = MINIMUM_STAKE - 1;

        vm.startPrank(user1);
        stakingToken.approve(address(staking), stakeAmount * 10 ** 18);

        vm.expectRevert(
            abi.encodeWithSelector(
                Staking__InvalidInput.selector,
                "Amount must be greater than minimum stake"
            )
        );
        staking.stake(stakeAmount);

        vm.stopPrank();
    }

    function test_Stake_AdditionalAmount() public {
        uint256 firstStake = 500;
        uint256 secondStake = 300;
        uint256 totalStake = (firstStake + secondStake) * 10 ** 18;

        vm.startPrank(user1);

        stakingToken.approve(address(staking), firstStake * 10 ** 18);
        staking.stake(firstStake);

        stakingToken.approve(address(staking), secondStake * 10 ** 18);
        staking.stake(secondStake);

        vm.stopPrank();

        (uint256 amount, , , bool active, , ) = staking.getStakeInfo(user1);

        assertEq(amount, totalStake);
        assertTrue(active);
        assertEq(staking.totalStaked(), totalStake);
    }

    function test_Unstake_RevertBeforeDuration() public {
        uint256 stakeAmount = 500;

        vm.startPrank(user1);

        stakingToken.approve(address(staking), stakeAmount * 10 ** 18);
        staking.stake(stakeAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                Staking__ActionNotAllowed.selector,
                "Staking period not completed"
            )
        );
        staking.unstake();

        vm.stopPrank();
    }

    function test_Unstake_AfterDuration() public {
        uint256 stakeAmount = 500;
        uint256 stakeAmountWithDecimals = stakeAmount * 10 ** 18;

        vm.startPrank(user1);

        stakingToken.approve(address(staking), stakeAmountWithDecimals);
        staking.stake(stakeAmount);

        vm.warp(block.timestamp + STAKING_DURATION + 1);

        uint256 balanceBefore = stakingToken.balanceOf(user1);

        uint256 expectedReward = calculateExpectedReward(
            stakeAmountWithDecimals,
            STAKING_DURATION + 1
        );

        vm.expectEmit(true, true, true, true);
        emit Unstaked(user1, stakeAmountWithDecimals);

        staking.unstake();

        vm.stopPrank();

        (uint256 amount, , , bool active, , ) = staking.getStakeInfo(user1);

        assertEq(amount, 0);
        assertFalse(active);
        assertEq(staking.totalStaked(), 0);

        uint256 balanceAfter = stakingToken.balanceOf(user1);
        assertEq(
            balanceAfter,
            balanceBefore + stakeAmountWithDecimals + expectedReward
        );
    }

    function test_ClaimReward_RevertBeforeDuration() public {
        uint256 stakeAmount = 500;

        vm.startPrank(user1);

        stakingToken.approve(address(staking), stakeAmount * 10 ** 18);
        staking.stake(stakeAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                Staking__ActionNotAllowed.selector,
                "Staking period not completed"
            )
        );
        staking.claimReward();

        vm.stopPrank();
    }

    function test_ClaimReward_AfterDuration() public {
        uint256 stakeAmount = 1000;
        uint256 stakeAmountWithDecimals = stakeAmount * 10 ** 18;

        vm.startPrank(user1);

        stakingToken.approve(address(staking), stakeAmountWithDecimals);
        staking.stake(stakeAmount);

        vm.warp(block.timestamp + STAKING_DURATION);

        uint256 balanceBefore = stakingToken.balanceOf(user1);

        uint256 expectedReward = calculateExpectedReward(
            stakeAmountWithDecimals,
            STAKING_DURATION
        );

        console.log("Claiming reward of %s tokens", expectedReward);

        vm.expectEmit(true, true, true, true);
        emit RewardClaimed(user1, expectedReward);

        uint256 claimedReward = staking.claimReward();
        console.log("Claimed reward: %s tokens", claimedReward);
        vm.stopPrank();

        assertEq(claimedReward, expectedReward);

        uint256 balanceAfter = stakingToken.balanceOf(user1);
        assertEq(balanceAfter, balanceBefore + expectedReward);

        (uint256 amount, , uint256 lastClaimTime, bool active, , ) = staking
            .getStakeInfo(user1);

        assertEq(amount, stakeAmountWithDecimals);
        assertEq(lastClaimTime, block.timestamp);
        assertTrue(active);
    }

    function test_ClaimReward_MultipleClaims() public {
        uint256 stakeAmount = 1000;
        uint256 stakeAmountWithDecimals = stakeAmount * 10 ** 18;

        vm.startPrank(user1);

        stakingToken.approve(address(staking), stakeAmountWithDecimals);
        staking.stake(stakeAmount);

        vm.warp(block.timestamp + STAKING_DURATION + 1);

        staking.claimReward();

        uint256 secondClaimDuration = 30 days;
        vm.warp(block.timestamp + secondClaimDuration);

        uint256 expectedReward = calculateExpectedReward(
            stakeAmountWithDecimals,
            secondClaimDuration
        );

        uint256 claimedReward = staking.claimReward();

        vm.stopPrank();

        assertEq(claimedReward, expectedReward);
    }

    function test_withdraw() public {
        MockERC20 otherToken = new MockERC20("Other Token", "OTK", 18);
        otherToken.mint(address(staking), 1000 ether);

        uint256 contractBalance = otherToken.balanceOf(address(staking));
        uint256 ownerBalanceBefore = otherToken.balanceOf(owner);

        staking.withdraw(address(otherToken));

        assertEq(
            otherToken.balanceOf(owner),
            ownerBalanceBefore + contractBalance
        );
        assertEq(otherToken.balanceOf(address(staking)), 0);
    }

    function test_withdraw_RevertIfStakingToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Staking__InvalidInput.selector,
                "Invalid token address"
            )
        );
        staking.withdraw(address(stakingToken));
    }

    function test_OnlyOwner() public {
        vm.startPrank(user1);

        vm.expectRevert();
        staking.updateAPY(1000);

        vm.expectRevert();
        staking.updateMinimumStake(200);

        vm.expectRevert();
        staking.updateStakingDuration(60 days);

        vm.expectRevert();
        staking.withdraw(address(1));

        vm.stopPrank();
    }

    function testWithdrawThroughUserOperation() public {
        // MockERC20(stakingToken).mint(address(staking), 1000 ether);

        bytes memory callData = abi.encodeWithSignature(
            "withdraw(address)",
            address(0x123)
        );

        PackedUserOperation memory op;
        op.sender = address(wallet);
        op.nonce = 0;
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            address(staking),
            0,
            callData
        );
        // op.callGasLimit = 1_000_000;
        // op.verificationGasLimit = 1_000_000;
        op.preVerificationGas = 21000;
        // op.maxFeePerGas = 1;
        // op.maxPriorityFeePerGas = 1;
        op.paymasterAndData = "";
        op.initCode = "";
        bytes32 hash = entryPoint.getUserOpHash(op);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk1, hash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk2, hash);

        bytes memory sig = abi.encodePacked(
            bytes.concat(r1, s1, bytes1(v1)),
            bytes.concat(r2, s2, bytes1(v2))
        );
        op.signature = sig;

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        entryPoint.handleOps(ops, payable(address(0xBEEF)));
    }

    function calculateExpectedReward(
        uint256 amount,
        uint256 timeElapsed
    ) internal pure returns (uint256) {
        uint256 reward = (amount * APY * timeElapsed) / (365 days * 10000);
        return reward;
    }
}
