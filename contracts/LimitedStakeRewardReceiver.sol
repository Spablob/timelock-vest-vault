// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { ILimitedStakeRewardReceiver } from "./interfaces/ILimitedStakeRewardReceiver.sol";

///  @title LimitedStakeRewardReceiver
///  @notice Manages a custom time-locked unlocking logic for token rewards
///  @dev Since block.timestamp is used, miner manipulation risk should be mentioned with
///  more information that can be found here: https://www.halborn.com/blog/post/what-is-timestamp-dependence
contract LimitedStakeRewardReceiver is ILimitedStakeRewardReceiver {
    /// @notice The hashed beneficiary address
    bytes32 public constant BENEFICIARY = 0x8db6ec5b3d82a244eabfda6181bd25b3f6975b4dac11bdc43979fd7f4baed342; // TODO: update to the actual value
    /// @notice The treasury address
    address public constant TREASURY = 0xb150dfd9539eDB8e0B19caA5ca37cf85Df487cC0; // TODO: update to the actual value
    /// @notice The unlock timestamp
    uint256 public constant UNLOCK_TIMESTAMP = 1767446400; // TODO: update to the actual value
    /// @notice The pre-unlock time maximum claimable rewards limit
    uint256 public constant PRE_UNLOCK_MAX_REWARDS = 100; // TODO: update to the actual value
    /// @notice The post-unlock time maximum claimable rewards limit
    uint256 public constant POST_UNLOCK_MAX_REWARDS = 200; // TODO: update to the actual value

    /// @notice The total claimed rewards so far
    uint256 public totalClaimed;

    // Custom errors
    error NotBeneficiary();
    error NoRewardsToClaim();
    error NotEnoughRewardsToForward();

    /// @notice Claims the beneficiary's rewards
    function claimRewards() external {
        if (_toHash(msg.sender) != BENEFICIARY) revert NotBeneficiary();

        uint256 claimableAmount = _getClaimableAmount(); 
        if (claimableAmount == 0) revert NoRewardsToClaim();

        totalClaimed += claimableAmount;

        Address.sendValue(payable(msg.sender), claimableAmount);

        emit RewardsClaimed(claimableAmount);
    }

    /// @notice Forwards excess rewards to the treasury
    function forwardExcessRewards() external {
        // totalReceived = totalClaimed + address(this).balance + any amount previously forwarded.
        // excessAmount at the function calling moment can ignore any amount previously forwarded amounts
        // hence only using totalClaimed + address(this).balance
        uint256 totalClaimedPlusBalance = totalClaimed + address(this).balance;
        if (totalClaimedPlusBalance <= POST_UNLOCK_MAX_REWARDS) revert NotEnoughRewardsToForward();

        uint256 excessAmount = totalClaimedPlusBalance - POST_UNLOCK_MAX_REWARDS;

        Address.sendValue(payable(TREASURY), excessAmount);

        emit ExcessRewardsForwarded(excessAmount);
    }

    /// @notice Returns the remaining total amount of rewards that can be claimed depending on the current timestamp
    /// @return The remaining total amount of rewards that can be claimed
    function getRemainingTotalAmount() external view returns (uint256) {
        uint256 amountClaimed = totalClaimed;
        if (block.timestamp <= UNLOCK_TIMESTAMP) {
            // amountClaimed does not exceed PRE_UNLOCK_MAX_REWARDS before UNLOCK_TIMESTAMP due to _getClaimableAmount() logic
            return PRE_UNLOCK_MAX_REWARDS - amountClaimed;
        } else {
            // amountClaimed does not exceed POST_UNLOCK_MAX_REWARDS after UNLOCK_TIMESTAMP due to _getClaimableAmount() logic
            return POST_UNLOCK_MAX_REWARDS - amountClaimed;
        }
    }

    /// @notice Returns the amount of rewards that can be claimed by the beneficiary
    /// @return The amount of rewards that can be claimed by the beneficiary
    function getClaimableAmount() external view returns (uint256) {
        return _getClaimableAmount();
    }

    receive() external payable {}

    /// @notice Returns the amount of rewards that can be claimed by the beneficiary
    /// @return claimableAmount The amount of rewards that can be claimed by the beneficiary
    function _getClaimableAmount() internal view returns (uint256 claimableAmount) {
        uint256 amountClaimed = totalClaimed;
        uint256 maxClaimableAmount;

        if (block.timestamp <= UNLOCK_TIMESTAMP) {
            if (amountClaimed > PRE_UNLOCK_MAX_REWARDS) return 0;
            maxClaimableAmount = PRE_UNLOCK_MAX_REWARDS - amountClaimed;
        } else {
            if (amountClaimed > POST_UNLOCK_MAX_REWARDS) return 0;
            maxClaimableAmount = POST_UNLOCK_MAX_REWARDS - amountClaimed;
        }

        claimableAmount = Math.min(maxClaimableAmount, address(this).balance);
    }

    /// @dev Returns the hashed beneficiary address
    /// @param addr The address to hash
    /// @return The hashed beneficiary address
    function _toHash(address addr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(addr));
    }
}
