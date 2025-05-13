// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ILimitedStakeRewardReceiver
/// @notice Interface for ILimitedStakeRewardReceiver. One beneficiary has one ILimitedStakeRewardReceiver.
/// It is used to receive the staking rewards of the beneficiary
interface ILimitedStakeRewardReceiver {
    // @notice Emitted when the beneficiary claims their rewards
    event RewardsClaimed(uint256 amount);
    // @notice Emitted when excess rewards are forwarded to the treasury
    event ExcessRewardsForwarded(uint256 amount);

    // Functions
    /// @notice Claims the beneficiary's rewards
    function claimRewards() external;

    /// @notice Forwards excess rewards to the treasury
    function forwardExcessRewards() external;

    /// @notice Returns the remaining total amount of rewards that can be claimed depending on the current timestamp
    /// @return The remaining total amount of rewards that can be claimed
    function getRemainingTotalAmount() external view returns (uint256);

    /// @notice Returns the amount of rewards that can be claimed by the beneficiary
    /// @return The amount of rewards that can be claimed by the beneficiary
    function getClaimableAmount() external view returns (uint256);
}
