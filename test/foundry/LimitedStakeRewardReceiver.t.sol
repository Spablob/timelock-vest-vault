// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { LimitedStakeRewardReceiver } from "../../contracts/LimitedStakeRewardReceiver.sol";
import { ILimitedStakeRewardReceiver } from "../../contracts/interfaces/ILimitedStakeRewardReceiver.sol";
import { IIPTokenStaking } from "../../contracts/interfaces/IIPTokenStaking.sol";

contract LimitedStakeRewardReceiverTest is Test {

    LimitedStakeRewardReceiver public limitedStakeRewardReceiver;
    IIPTokenStaking stakingContract;
    address public beneficiary;

    function setUp() public {
        uint256 forkId = vm.createFork("https://aeneid.storyrpc.io");
        vm.selectFork(forkId);

        limitedStakeRewardReceiver = new LimitedStakeRewardReceiver();
        stakingContract = IIPTokenStaking(address(0xCCcCcC0000000000000000000000000000000001));

        beneficiary = 0x0aD06C3639E7Ef9F77c2b7057F5Ddf7A49949C6D;
        bytes32 beneficiaryHash = keccak256(abi.encodePacked(beneficiary));
        // console2.logBytes32(beneficiaryHash);
        assertEq(limitedStakeRewardReceiver.BENEFICIARY(), beneficiaryHash);

        vm.label(address(limitedStakeRewardReceiver), "limitedStakeRewardReceiver");
        vm.label(address(stakingContract), "stakingContract");
        vm.label(beneficiary, "beneficiary");
        vm.label(limitedStakeRewardReceiver.TREASURY(), "treasury");
    }

    function test_claimRewards_revert_NotBeneficiary() public {
        vm.prank(address(11));
        vm.expectRevert(LimitedStakeRewardReceiver.NotBeneficiary.selector);
        limitedStakeRewardReceiver.claimRewards();
    }

    function test_claimRewards_revert_NoRewardsToClaim_EmptyVault() public {
        vm.prank(beneficiary);
        vm.expectRevert(LimitedStakeRewardReceiver.NoRewardsToClaim.selector);
        limitedStakeRewardReceiver.claimRewards();
    }

    function test_claimRewards_revert_NoRewardsToClaim_PreUnlockLimitReached() public {
        // fund the contract to simulate earned staking rewards
        vm.deal(address(limitedStakeRewardReceiver), limitedStakeRewardReceiver.PRE_UNLOCK_MAX_REWARDS() + 1);

        uint256 beneficiaryBalanceBefore = address(beneficiary).balance;

        vm.startPrank(beneficiary);
        limitedStakeRewardReceiver.claimRewards();

        uint256 beneficiaryBalanceAfter = address(beneficiary).balance;
        assertEq(beneficiaryBalanceAfter - beneficiaryBalanceBefore, limitedStakeRewardReceiver.PRE_UNLOCK_MAX_REWARDS());
        assertEq(address(limitedStakeRewardReceiver).balance, 1);

        vm.expectRevert(LimitedStakeRewardReceiver.NoRewardsToClaim.selector);
        limitedStakeRewardReceiver.claimRewards();
    }

    function test_claimRewards_revert_NoRewardsToClaim_PostUnlockLimitReached() public {
        vm.warp(block.timestamp + 1000 days);

        // fund the contract to simulate earned staking rewards
        vm.deal(address(limitedStakeRewardReceiver), limitedStakeRewardReceiver.POST_UNLOCK_MAX_REWARDS() + 1);

        uint256 beneficiaryBalanceBefore = address(beneficiary).balance;

        vm.startPrank(beneficiary);
        limitedStakeRewardReceiver.claimRewards();

        uint256 beneficiaryBalanceAfter = address(beneficiary).balance;
        assertEq(beneficiaryBalanceAfter - beneficiaryBalanceBefore, limitedStakeRewardReceiver.POST_UNLOCK_MAX_REWARDS());
        assertEq(address(limitedStakeRewardReceiver).balance, 1);
        
        vm.expectRevert(LimitedStakeRewardReceiver.NoRewardsToClaim.selector);
        limitedStakeRewardReceiver.claimRewards();
    }

    function test_claimRewards_PreUnlock() public {
        // fund the contract to simulate earned staking rewards
        uint256 rewards1 = limitedStakeRewardReceiver.PRE_UNLOCK_MAX_REWARDS() / 2;
        vm.deal(address(limitedStakeRewardReceiver), rewards1);

        assertEq(limitedStakeRewardReceiver.getClaimableAmount(), rewards1);

        uint256 beneficiaryBalanceBefore = address(beneficiary).balance;
        uint256 contractBalanceBefore = address(limitedStakeRewardReceiver).balance;
        uint256 totalClaimedBefore = limitedStakeRewardReceiver.totalClaimed();

        vm.expectEmit();
        emit ILimitedStakeRewardReceiver.RewardsClaimed(rewards1);

        vm.startPrank(beneficiary);
        limitedStakeRewardReceiver.claimRewards();

        uint256 beneficiaryBalanceAfter = address(beneficiary).balance;
        uint256 contractBalanceAfter = address(limitedStakeRewardReceiver).balance;
        uint256 totalClaimedAfter = limitedStakeRewardReceiver.totalClaimed();

        assertEq(beneficiaryBalanceAfter - beneficiaryBalanceBefore, rewards1);
        assertEq(contractBalanceBefore - contractBalanceAfter, rewards1);
        assertEq(totalClaimedAfter - totalClaimedBefore, rewards1);

        // fund the contract to simulate earned staking rewards
        uint256 rewards2 = limitedStakeRewardReceiver.PRE_UNLOCK_MAX_REWARDS() / 2;
        vm.deal(address(limitedStakeRewardReceiver), rewards2);

        uint256 beneficiaryBalanceBefore2 = address(beneficiary).balance;
        uint256 contractBalanceBefore2 = address(limitedStakeRewardReceiver).balance;
        uint256 totalClaimedBefore2 = limitedStakeRewardReceiver.totalClaimed();

        vm.expectEmit();
        emit ILimitedStakeRewardReceiver.RewardsClaimed(rewards2);

        vm.startPrank(beneficiary);
        limitedStakeRewardReceiver.claimRewards();

        uint256 beneficiaryBalanceAfter2 = address(beneficiary).balance;
        uint256 contractBalanceAfter2 = address(limitedStakeRewardReceiver).balance;
        uint256 totalClaimedAfter2 = limitedStakeRewardReceiver.totalClaimed();

        assertEq(beneficiaryBalanceAfter2 - beneficiaryBalanceBefore2, rewards2);
        assertEq(contractBalanceBefore2 - contractBalanceAfter2, rewards2);
        assertEq(totalClaimedAfter2 - totalClaimedBefore2, rewards2);
    }

    function test_claimRewards_PostUnlock() public {
        vm.warp(block.timestamp + 1000 days);

        // fund the contract to simulate earned staking rewards
        uint256 rewards1 = limitedStakeRewardReceiver.POST_UNLOCK_MAX_REWARDS() / 2;
        vm.deal(address(limitedStakeRewardReceiver), rewards1);

        uint256 beneficiaryBalanceBefore = address(beneficiary).balance;
        uint256 contractBalanceBefore = address(limitedStakeRewardReceiver).balance;
        uint256 totalClaimedBefore = limitedStakeRewardReceiver.totalClaimed();

        vm.expectEmit();
        emit ILimitedStakeRewardReceiver.RewardsClaimed(rewards1);

        vm.startPrank(beneficiary);
        limitedStakeRewardReceiver.claimRewards();

        uint256 beneficiaryBalanceAfter = address(beneficiary).balance;
        uint256 contractBalanceAfter = address(limitedStakeRewardReceiver).balance;
        uint256 totalClaimedAfter = limitedStakeRewardReceiver.totalClaimed();

        assertEq(beneficiaryBalanceAfter - beneficiaryBalanceBefore, rewards1);
        assertEq(contractBalanceBefore - contractBalanceAfter, rewards1);
        assertEq(totalClaimedAfter - totalClaimedBefore, rewards1);

        // fund the contract to simulate earned staking rewards
        uint256 rewards2 = limitedStakeRewardReceiver.POST_UNLOCK_MAX_REWARDS() / 2;
        vm.deal(address(limitedStakeRewardReceiver), rewards2);

        uint256 beneficiaryBalanceBefore2 = address(beneficiary).balance;
        uint256 contractBalanceBefore2 = address(limitedStakeRewardReceiver).balance;
        uint256 totalClaimedBefore2 = limitedStakeRewardReceiver.totalClaimed();

        vm.expectEmit();
        emit ILimitedStakeRewardReceiver.RewardsClaimed(rewards2);

        vm.startPrank(beneficiary);
        limitedStakeRewardReceiver.claimRewards();

        uint256 beneficiaryBalanceAfter2 = address(beneficiary).balance;
        uint256 contractBalanceAfter2 = address(limitedStakeRewardReceiver).balance;
        uint256 totalClaimedAfter2 = limitedStakeRewardReceiver.totalClaimed();

        assertEq(beneficiaryBalanceAfter2 - beneficiaryBalanceBefore2, rewards2);
        assertEq(contractBalanceBefore2 - contractBalanceAfter2, rewards2);
        assertEq(totalClaimedAfter2 - totalClaimedBefore2, rewards2);
    }

    function test_forwardExcessRewards_revert_NotEnoughRewardsToForward() public {
        vm.deal(address(limitedStakeRewardReceiver), limitedStakeRewardReceiver.POST_UNLOCK_MAX_REWARDS());

        vm.expectRevert(LimitedStakeRewardReceiver.NotEnoughRewardsToForward.selector);
        limitedStakeRewardReceiver.forwardExcessRewards();

        vm.startPrank(beneficiary);
        limitedStakeRewardReceiver.claimRewards();

        vm.expectRevert(LimitedStakeRewardReceiver.NotEnoughRewardsToForward.selector);
        limitedStakeRewardReceiver.forwardExcessRewards(); 

        uint256 remainingBalance = limitedStakeRewardReceiver.POST_UNLOCK_MAX_REWARDS() - limitedStakeRewardReceiver.PRE_UNLOCK_MAX_REWARDS();
        assertEq(address(limitedStakeRewardReceiver).balance, remainingBalance);
    }

    function test_forwardExcessRewards() public {
        vm.deal(address(limitedStakeRewardReceiver), limitedStakeRewardReceiver.POST_UNLOCK_MAX_REWARDS() + 1);

        uint256 treasuryBalanceBefore = address(limitedStakeRewardReceiver.TREASURY()).balance;
        uint256 contractBalanceBefore = address(limitedStakeRewardReceiver).balance;

        vm.expectEmit();
        emit ILimitedStakeRewardReceiver.ExcessRewardsForwarded(1);

        limitedStakeRewardReceiver.forwardExcessRewards(); 

        uint256 treasuryBalanceAfter = address(limitedStakeRewardReceiver.TREASURY()).balance;
        uint256 contractBalanceAfter = address(limitedStakeRewardReceiver).balance;

        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, 1);
        assertEq(contractBalanceBefore - contractBalanceAfter, 1);
    }

    function test_getRemainingTotalAmount_PreUnlock() public {
        // fund the contract to simulate earned staking rewards
        uint256 rewards = limitedStakeRewardReceiver.PRE_UNLOCK_MAX_REWARDS();
        vm.deal(address(limitedStakeRewardReceiver), rewards);

        uint256 remainingAmount = limitedStakeRewardReceiver.getRemainingTotalAmount();
        assertEq(remainingAmount, limitedStakeRewardReceiver.PRE_UNLOCK_MAX_REWARDS());

        vm.startPrank(beneficiary);
        limitedStakeRewardReceiver.claimRewards();

        remainingAmount = limitedStakeRewardReceiver.getRemainingTotalAmount();
        assertEq(remainingAmount, 0);
    }

    function test_getRemainingTotalAmount_PostUnlock() public {
        vm.warp(block.timestamp + 1000 days);

        // fund the contract to simulate earned staking rewards
        uint256 rewards = limitedStakeRewardReceiver.POST_UNLOCK_MAX_REWARDS();
        vm.deal(address(limitedStakeRewardReceiver), rewards);

        uint256 remainingAmount = limitedStakeRewardReceiver.getRemainingTotalAmount();
        assertEq(remainingAmount, limitedStakeRewardReceiver.POST_UNLOCK_MAX_REWARDS());

        vm.startPrank(beneficiary);
        limitedStakeRewardReceiver.claimRewards();

        remainingAmount = limitedStakeRewardReceiver.getRemainingTotalAmount();
        assertEq(remainingAmount, 0);
    }
}

